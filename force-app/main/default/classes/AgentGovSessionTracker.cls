/**
 * @description Keeps each agent's session current. A session is one run of governed activity:
 *              it opens on the agent's first governed action, collects that run's usage and
 *              action count, and closes once the agent has been idle for the window in
 *              AgentGov_Settings__c.Session_Idle_Minutes__c or has run for
 *              AgentGovConstants.MAX_SESSION_HOURS. The agent's next governed action then opens
 *              a new session. Callers never have to manage sessions, although
 *              AgentGovRegistryService.startSession and endSession remain for callers that want
 *              explicit boundaries.
 *
 *              Activity is recorded from AgentGovBudgetManager.consumeBudgets while the
 *              transaction holds the agent's budget row lock, which serializes the common case.
 *              The unique Active_Session_Key__c covers every other case: at most one Active
 *              session can exist per agent, and a transaction that loses the race to open one
 *              adds its usage to the winning session instead.
 *
 *              Sessions are secondary to the budget ledger. A failure to record one is written
 *              to the action log as a System row and never denies the agent's action.
 *
 *              Security posture: inherited sharing. Reads go through AgentGovSelector and
 *              writes through AgentGovDml, both of which run in system mode.
 */
public inherited sharing class AgentGovSessionTracker {
    // The session each agent's activity was recorded against in this transaction, so audit
    // rows written later in the same request can link to it.
    private static Map<Id, Id> currentSessions = new Map<Id, Id>();

    // Lets a test reproduce a lost race: the tracker behaves as if it had not seen the
    // agent's open session, so its insert collides with the unique key.
    @TestVisible
    private static Boolean simulateMissedSession = false;

    /**
     * @description Records governed activity. Adds usage and actions to each agent's live
     *              session, closing a stale session and opening a new one where needed, and
     *              keeps each agent's Last_Active__c current.
     * @param usageByAgent Map of registration Id to the units consumed, by limit type
     * @param actionsByAgent Map of registration Id to the governed actions performed; an
     *                       agent that is absent performed none, as for a usage report
     */
    public static void recordActivity(Map<Id, Map<String, Integer>> usageByAgent, Map<Id, Integer> actionsByAgent) {
        Set<Id> agentIds = new Set<Id>();
        if (usageByAgent != null) {
            for (Id agentId : usageByAgent.keySet()) {
                if (agentId != null) {
                    agentIds.add(agentId);
                }
            }
        }
        if (agentIds.isEmpty()) {
            return;
        }
        DateTime now = DateTime.now();
        List<AgentGov_Action_Log__c> notes = new List<AgentGov_Action_Log__c>();

        // When Last_Active__c is due, the registration is written, and so locked, before any
        // session row: the order deactivation, startSession and the health check use. When it is
        // not due, nothing here locks the registration, but the proxy and /report lock it after
        // this to record a failure, or a success on a breaker that is not CLOSED with no
        // failures. That reverses the order, so such a request and a concurrent deactivation or
        // startSession for the same agent can deadlock, and one of them fails with a lock error.
        touchRegistrations(agentIds, now, notes);

        Map<Id, AgentGov_Session__c> active = simulateMissedSession
            ? new Map<Id, AgentGov_Session__c>()
            : AgentGovSelector.getActiveSessionsForUpdate(agentIds);
        Integer idleMinutes = idleMinutes();
        List<AgentGov_Session__c> closing = new List<AgentGov_Session__c>();
        List<AgentGov_Session__c> extending = new List<AgentGov_Session__c>();
        List<AgentGov_Session__c> opening = new List<AgentGov_Session__c>();
        for (Id agentId : agentIds) {
            AgentGov_Session__c session = active.get(agentId);
            Map<String, Integer> usage = usageByAgent.get(agentId);
            Integer actions = actionCount(actionsByAgent, agentId);
            if (session != null && isLive(session, now, idleMinutes)) {
                extending.add(withActivity(session, usage, actions, now));
                currentSessions.put(agentId, session.Id);
                continue;
            }
            if (session != null) {
                closing.add(
                    ended(
                        session,
                        AgentGovConstants.SESSION_COMPLETED,
                        endReason(session, now),
                        lastActivityOf(session)
                    )
                );
            }
            opening.add(newSession(agentId, usage, actions, now));
        }

        // Closing first clears the stale session's key, which the new session then takes.
        save(closing, 'Session could not be closed', notes);
        save(extending, 'Session usage could not be recorded', notes);
        openSessions(opening, usageByAgent, actionsByAgent, now, notes);
        AgentGovTriggerHandler.recordFrameworkEvents(notes);
    }

    /**
     * @description Returns the session this transaction recorded the agent's activity
     *              against, or null when no activity was recorded for it.
     * @param registrationId The agent registration Id
     * @return The session Id, or null
     */
    public static Id currentSessionFor(Id registrationId) {
        return registrationId == null ? null : currentSessions.get(registrationId);
    }

    /**
     * @description Starts a new session for an agent on the caller's request, ending the
     *              agent's current one first so that the agent never has two open sessions.
     * @param registrationId The agent registration Id
     * @return The new session
     */
    public static AgentGov_Session__c startSession(Id registrationId) {
        DateTime now = DateTime.now();
        List<AgentGov_Session__c> current = AgentGovSelector.getAllActiveSessionsForUpdate(
            new Set<Id>{ registrationId }
        );
        List<AgentGov_Session__c> closing = new List<AgentGov_Session__c>();
        for (AgentGov_Session__c session : current) {
            closing.add(ended(session, AgentGovConstants.SESSION_COMPLETED, AgentGovConstants.SESSION_END_CALLER, now));
        }
        AgentGovDml.assertAllSucceeded(AgentGovDml.updateRecords(closing, false), 'Session close');
        AgentGov_Session__c session = newSession(registrationId, null, 0, now);
        AgentGovDml.insertRecord(session);
        currentSessions.put(registrationId, session.Id);
        return session;
    }

    /**
     * @description Ends the given sessions now. Sessions that are no longer active are left
     *              as they are, so their recorded end time is never rewritten.
     * @param sessionIds Sessions to end
     * @param status Completed or Terminated
     * @param reason One of the AgentGovConstants.SESSION_END_* values
     * @return The sessions that were ended
     */
    public static List<AgentGov_Session__c> endSessions(Set<Id> sessionIds, String status, String reason) {
        DateTime now = DateTime.now();
        List<AgentGov_Session__c> changed = new List<AgentGov_Session__c>();
        for (AgentGov_Session__c session : AgentGovSelector.getSessionsForUpdate(sessionIds).values()) {
            if (session.Status__c == AgentGovConstants.SESSION_ACTIVE) {
                changed.add(ended(session, status, reason, now));
            }
        }
        AgentGovDml.assertAllSucceeded(AgentGovDml.updateRecords(changed, false), 'Session end');
        return changed;
    }

    /**
     * @description Ends every active session of the given agents, including duplicates left
     *              by releases before v1.3. Used when agents are deactivated.
     * @param registrationIds Agents whose sessions to end
     * @param reason One of the AgentGovConstants.SESSION_END_* values
     * @return The sessions that were ended
     */
    public static List<AgentGov_Session__c> endAllForAgents(Set<Id> registrationIds, String reason) {
        DateTime now = DateTime.now();
        List<AgentGov_Session__c> changed = new List<AgentGov_Session__c>();
        for (AgentGov_Session__c session : AgentGovSelector.getAllActiveSessionsForUpdate(registrationIds)) {
            changed.add(ended(session, AgentGovConstants.SESSION_TERMINATED, reason, now));
        }
        AgentGovDml.assertAllSucceeded(AgentGovDml.updateRecords(changed, false), 'Session end');
        return changed;
    }

    /**
     * @description Closes sessions that have gone idle or run past the maximum duration.
     *              Called by the scheduled health check, so sessions end on time even when an
     *              agent never calls again. Each session's end time is its last activity.
     * @param maxRows Most sessions to close in one run
     * @return The number of sessions closed
     */
    public static Integer closeStale(Integer maxRows) {
        DateTime now = DateTime.now();
        Integer idleMinutes = idleMinutes();
        List<AgentGov_Session__c> candidates = AgentGovSelector.getStaleSessions(
            now.addMinutes(-idleMinutes),
            now.addHours(-AgentGovConstants.MAX_SESSION_HOURS),
            maxRows
        );
        if (candidates.isEmpty()) {
            return 0;
        }
        // Re-read under a lock and re-check. The agent may have acted again since the unlocked
        // read above, and closing a session that is live again would split one run in two.
        List<AgentGov_Session__c> closing = new List<AgentGov_Session__c>();
        Set<Id> candidateIds = new Map<Id, AgentGov_Session__c>(candidates).keySet();
        for (AgentGov_Session__c session : AgentGovSelector.getSessionsForUpdate(candidateIds).values()) {
            if (session.Status__c == AgentGovConstants.SESSION_ACTIVE && !isLive(session, now, idleMinutes)) {
                closing.add(
                    ended(
                        session,
                        AgentGovConstants.SESSION_COMPLETED,
                        endReason(session, now),
                        lastActivityOf(session)
                    )
                );
            }
        }
        AgentGovDml.assertAllSucceeded(AgentGovDml.updateRecords(closing, false), 'Stale session close');
        return closing.size();
    }

    // --- Private helpers ---

    private static void openSessions(
        List<AgentGov_Session__c> opening,
        Map<Id, Map<String, Integer>> usageByAgent,
        Map<Id, Integer> actionsByAgent,
        DateTime now,
        List<AgentGov_Action_Log__c> notes
    ) {
        if (opening.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = AgentGovDml.insertRecords(opening, false);
        Set<Id> lostRace = new Set<Id>();
        for (Integer i = 0; i < results.size(); i++) {
            Id agentId = opening[i].Agent_Registration__c;
            if (results[i].isSuccess()) {
                currentSessions.put(agentId, results[i].getId());
            } else if (AgentGovDml.isDuplicateValueFailure(results[i])) {
                lostRace.add(agentId);
            } else {
                notes.add(
                    AgentGovTriggerHandler.buildFrameworkEvent(
                        agentId,
                        AgentGovConstants.ACTION_FAILURE,
                        'Session could not be opened.',
                        AgentGovDml.describeErrors(results[i].getErrors())
                    )
                );
            }
        }
        if (lostRace.isEmpty()) {
            return;
        }
        // Another transaction opened the agent's session first. This transaction's usage
        // belongs to the same run, so it is added to that session rather than dropped.
        List<AgentGov_Session__c> joining = new List<AgentGov_Session__c>();
        for (AgentGov_Session__c winner : AgentGovSelector.getActiveSessionsForUpdate(lostRace).values()) {
            Id agentId = winner.Agent_Registration__c;
            joining.add(withActivity(winner, usageByAgent.get(agentId), actionCount(actionsByAgent, agentId), now));
            currentSessions.put(agentId, winner.Id);
        }
        save(joining, 'Session usage could not be recorded', notes);
    }

    private static void touchRegistrations(Set<Id> agentIds, DateTime now, List<AgentGov_Action_Log__c> notes) {
        List<AgentGov_Registration__c> stale = new List<AgentGov_Registration__c>();
        for (AgentGov_Registration__c registration : AgentGovSelector.getRegistrationsByIds(agentIds).values()) {
            Boolean due =
                registration.Last_Active__c == null ||
                registration.Last_Active__c.addSeconds(AgentGovConstants.LAST_ACTIVE_REFRESH_SECONDS) <= now;
            if (due) {
                stale.add(new AgentGov_Registration__c(Id = registration.Id, Last_Active__c = now));
                // Keeps the transaction's cached copy in step with the row just written.
                registration.Last_Active__c = now;
            }
        }
        if (stale.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = AgentGovDml.updateRecords(stale, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                notes.add(
                    AgentGovTriggerHandler.buildFrameworkEvent(
                        stale[i].Id,
                        AgentGovConstants.ACTION_FAILURE,
                        'Last active time could not be updated.',
                        AgentGovDml.describeErrors(results[i].getErrors())
                    )
                );
            }
        }
    }

    private static void save(List<AgentGov_Session__c> sessions, String failure, List<AgentGov_Action_Log__c> notes) {
        if (sessions.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = AgentGovDml.updateRecords(sessions, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                notes.add(
                    AgentGovTriggerHandler.buildFrameworkEvent(
                        null,
                        AgentGovConstants.ACTION_FAILURE,
                        failure + ' Session: ' + sessions[i].Id,
                        AgentGovDml.describeErrors(results[i].getErrors())
                    )
                );
            }
        }
    }

    private static Integer idleMinutes() {
        Decimal configured = AgentGovSelector.getSettings().Session_Idle_Minutes__c;
        if (configured == null || configured < 1 || configured > AgentGovConstants.MAX_SESSION_IDLE_MINUTES) {
            return AgentGovConstants.DEFAULT_SESSION_IDLE_MINUTES;
        }
        return configured.intValue();
    }

    private static Boolean isLive(AgentGov_Session__c session, DateTime now, Integer idleMinutes) {
        return lastActivityOf(session).addMinutes(idleMinutes) > now &&
            session.Session_Start__c.addHours(AgentGovConstants.MAX_SESSION_HOURS) > now;
    }

    // Sessions created before v1.3 have no recorded activity; their start stands in for it.
    private static DateTime lastActivityOf(AgentGov_Session__c session) {
        return session.Last_Activity__c != null ? session.Last_Activity__c : session.Session_Start__c;
    }

    private static String endReason(AgentGov_Session__c session, DateTime now) {
        return session.Session_Start__c.addHours(AgentGovConstants.MAX_SESSION_HOURS) <= now
            ? AgentGovConstants.SESSION_END_MAX_DURATION
            : AgentGovConstants.SESSION_END_IDLE;
    }

    private static Integer actionCount(Map<Id, Integer> actionsByAgent, Id agentId) {
        Integer count = actionsByAgent == null ? null : actionsByAgent.get(agentId);
        return count == null || count < 0 ? 0 : count;
    }

    private static Decimal amountOf(Map<String, Integer> usage, String limitType) {
        Integer amount = usage == null ? null : usage.get(limitType);
        return amount == null || amount < 0 ? 0 : amount;
    }

    private static Decimal orZero(Decimal value) {
        return value == null ? 0 : value;
    }

    private static AgentGov_Session__c newSession(
        Id agentId,
        Map<String, Integer> usage,
        Integer actions,
        DateTime now
    ) {
        return new AgentGov_Session__c(
            Agent_Registration__c = agentId,
            Session_Start__c = now,
            Last_Activity__c = now,
            Status__c = AgentGovConstants.SESSION_ACTIVE,
            API_Calls_Used__c = amountOf(usage, AgentGovConstants.LIMIT_API_CALLS),
            SOQL_Queries_Used__c = amountOf(usage, AgentGovConstants.LIMIT_SOQL_QUERIES),
            DML_Statements_Used__c = amountOf(usage, AgentGovConstants.LIMIT_DML_OPERATIONS),
            Actions_Count__c = actions
        );
    }

    // Only the changed fields are written, so a stale copy can never overwrite values that
    // another path set on the same session.
    private static AgentGov_Session__c withActivity(
        AgentGov_Session__c session,
        Map<String, Integer> usage,
        Integer actions,
        DateTime now
    ) {
        return new AgentGov_Session__c(
            Id = session.Id,
            Last_Activity__c = now,
            API_Calls_Used__c = orZero(session.API_Calls_Used__c) + amountOf(usage, AgentGovConstants.LIMIT_API_CALLS),
            SOQL_Queries_Used__c = orZero(session.SOQL_Queries_Used__c) +
                amountOf(usage, AgentGovConstants.LIMIT_SOQL_QUERIES),
            DML_Statements_Used__c = orZero(session.DML_Statements_Used__c) +
                amountOf(usage, AgentGovConstants.LIMIT_DML_OPERATIONS),
            Actions_Count__c = orZero(session.Actions_Count__c) + actions
        );
    }

    private static AgentGov_Session__c ended(
        AgentGov_Session__c session,
        String status,
        String reason,
        DateTime endAt
    ) {
        return new AgentGov_Session__c(
            Id = session.Id,
            Status__c = status,
            End_Reason__c = reason,
            Session_End__c = endAt
        );
    }
}
