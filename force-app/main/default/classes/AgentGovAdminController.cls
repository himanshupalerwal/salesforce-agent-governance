/**
 * @description Actions an administrator takes from the AgentGov console: reset circuit
 *              breakers, activate and deactivate agents, end sessions, credit budgets, rotate
 *              API keys, and schedule the background jobs.
 *
 *              Security posture: with sharing. Every method first checks a custom permission on
 *              the server: AgentGov_Operate_Agents, or AgentGov_Manage_Keys for key rotation. It
 *              then reads the target records WITH USER_MODE, so a user can only act on agents
 *              they can see, and only then calls the service classes, which write in system
 *              mode. Every change is recorded as an Admin row in the action log in the same
 *              transaction, all or nothing: there is never a change without its audit row, or
 *              an audit row for a change that did not happen. AgentGovDashboardController stays
 *              read-only and cacheable.
 *
 *              Operational failures are returned as outcomes rather than thrown, because a
 *              thrown exception would also roll back the System row that records the cause.
 */
public with sharing class AgentGovAdminController {
    // AgentGovConstants.LIMIT_LABELS names several units of a limit type; these name one.
    private static final Map<String, String> SINGULAR_LIMIT_LABELS = new Map<String, String>{
        AgentGovConstants.LIMIT_API_CALLS => 'API call',
        AgentGovConstants.LIMIT_SOQL_QUERIES => 'SOQL query',
        AgentGovConstants.LIMIT_DML_OPERATIONS => 'DML operation'
    };

    // Lets a test fail an action after its change and its audit rows are written, to prove that
    // both are undone together.
    @TestVisible
    private static Exception failureAfterAudit;

    /**
     * @description Outcome of an action for one record. success is true when the record ends
     *              in the state the action asks for, also when it was already in that state;
     *              the message says which.
     */
    public class ActionOutcome {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public Boolean success;
        @AuraEnabled
        public String message;
    }

    /** @description A newly issued API key. The key is returned once and never stored. */
    public class IssuedKey {
        @AuraEnabled
        public Boolean success;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public String apiKey;
        @AuraEnabled
        public String apiKeyPrefix;
        @AuraEnabled
        public DateTime rotatedAt;
    }

    /** @description What the console's setup checklist shows. */
    public class SetupStatus {
        @AuraEnabled
        public Boolean governanceEnabled;
        @AuraEnabled
        public Boolean realTimeEventsEnabled;
        @AuraEnabled
        public Boolean adminEmailConfigured;
        @AuraEnabled
        public Boolean notifyAgentOwners;
        @AuraEnabled
        public Integer sessionIdleMinutes;
        @AuraEnabled
        public List<AgentGovJobScheduler.JobStatus> jobs;
        @AuraEnabled
        public List<String> policyProblems;
    }

    /**
     * @description Closes the circuit breakers of the selected agents and reactivates the
     *              agents that their breakers had blocked.
     * @param registrationIds Agents to reset, at most 200
     * @return One outcome per requested agent
     */
    @AuraEnabled
    public static List<ActionOutcome> resetBreakers(List<Id> registrationIds) {
        requireOperate();
        Map<Id, AgentGov_Registration__c> targets = visibleRegistrations(registrationIds);
        AgentGovRequestContext.begin(null);
        Savepoint savepoint = Database.setSavepoint();
        try {
            AgentGovCircuitBreaker.resetBreakers(targets.keySet());
            audit(
                describeEach(
                    targets.values(),
                    'Circuit breaker reset from the console. It was ',
                    'Circuit_Breaker_State__c'
                )
            );
            return outcomes(registrationIds, sameMessage(targets.keySet(), 'Circuit breaker closed.'));
        } catch (Exception e) {
            return failed(savepoint, registrationIds, 'The circuit breakers could not be reset.', e);
        }
    }

    /**
     * @description Activates the selected agents, subject to the org's concurrent-agent limit.
     *              An agent that is already active is left as it is and gets no audit row.
     * @param registrationIds Agents to activate, at most 200
     * @return One outcome per requested agent
     */
    @AuraEnabled
    public static List<ActionOutcome> activateAgents(List<Id> registrationIds) {
        requireOperate();
        Map<Id, AgentGov_Registration__c> targets = visibleRegistrations(registrationIds);
        Map<Id, AgentGov_Registration__c> changing = withStatusOtherThan(targets, AgentGovConstants.STATUS_ACTIVE);
        AgentGovRequestContext.begin(null);
        Savepoint savepoint = Database.setSavepoint();
        try {
            if (!changing.isEmpty()) {
                AgentGovRegistryService.activateAgents(changing.keySet());
                audit(
                    describeEach(changing.values(), 'Agent activated from the console. Its status was ', 'Status__c')
                );
            }
            return outcomes(
                registrationIds,
                changedOrNot(targets.keySet(), changing.keySet(), 'Agent activated.', 'The agent was already active.')
            );
        } catch (Exception e) {
            return failed(savepoint, registrationIds, 'The agents could not be activated.', e);
        }
    }

    /**
     * @description Deactivates the selected agents and ends their sessions. A deactivated
     *              agent is refused at every governed entry point until it is activated again.
     *              An agent that is already inactive is left as it is and gets no audit row.
     * @param registrationIds Agents to deactivate, at most 200
     * @return One outcome per requested agent
     */
    @AuraEnabled
    public static List<ActionOutcome> deactivateAgents(List<Id> registrationIds) {
        requireOperate();
        Map<Id, AgentGov_Registration__c> targets = visibleRegistrations(registrationIds);
        Map<Id, AgentGov_Registration__c> changing = withStatusOtherThan(targets, AgentGovConstants.STATUS_INACTIVE);
        AgentGovRequestContext.begin(null);
        Savepoint savepoint = Database.setSavepoint();
        try {
            if (!changing.isEmpty()) {
                AgentGovRegistryService.deactivateAgents(changing.keySet());
                audit(
                    describeEach(changing.values(), 'Agent deactivated from the console. Its status was ', 'Status__c')
                );
            }
            return outcomes(
                registrationIds,
                changedOrNot(
                    targets.keySet(),
                    changing.keySet(),
                    'Agent deactivated.',
                    'The agent was already inactive.'
                )
            );
        } catch (Exception e) {
            return failed(savepoint, registrationIds, 'The agents could not be deactivated.', e);
        }
    }

    /**
     * @description Ends the selected sessions. The agents keep working; their next governed
     *              call opens a new session. A session that had already ended is left as it is
     *              and gets no audit row.
     * @param sessionIds Sessions to end, at most 200
     * @return One outcome per requested session
     */
    @AuraEnabled
    public static List<ActionOutcome> endSessions(List<Id> sessionIds) {
        requireOperate();
        Set<Id> requested = requireSelection(sessionIds);
        Map<Id, AgentGov_Session__c> targets;
        try {
            targets = new Map<Id, AgentGov_Session__c>(
                [SELECT Id, Agent_Registration__c FROM AgentGov_Session__c WHERE Id IN :requested WITH USER_MODE]
            );
        } catch (Exception e) {
            throw auraError(AgentGovConstants.ERR_NO_RECORD_ACCESS);
        }
        AgentGovRequestContext.begin(null);
        Savepoint savepoint = Database.setSavepoint();
        try {
            List<AgentGov_Session__c> ended = AgentGovRegistryService.terminateSessions(targets.keySet());
            Set<Id> endedIds = new Set<Id>();
            List<AgentGov_Action_Log__c> rows = new List<AgentGov_Action_Log__c>();
            for (AgentGov_Session__c session : ended) {
                endedIds.add(session.Id);
                rows.add(
                    adminRow(
                        targets.get(session.Id).Agent_Registration__c,
                        'Session ' + session.Id + ' ended from the console.'
                    )
                );
            }
            writeAudit(rows);
            return outcomes(
                sessionIds,
                changedOrNot(targets.keySet(), endedIds, 'Session ended.', 'The session had already ended.')
            );
        } catch (Exception e) {
            return failed(savepoint, sessionIds, 'The sessions could not be ended.', e);
        }
    }

    /**
     * @description Credits usage of one limit type back to an agent's budget for today, the
     *              current day in the org's time zone, for example after an incident was
     *              resolved. Usage never goes below zero, so a credit larger than today's usage
     *              brings it to zero, and the outcome and the audit row say how much was
     *              actually credited. The budget status is re-evaluated from the corrected
     *              usage, so a Blocked budget can return to a lower status. When nothing of the
     *              limit type has been used today, nothing changes and the outcome says so.
     * @param registrationId The agent
     * @param limitType API_Calls, SOQL_Queries, or DML_Operations
     * @param amount Units to credit back, at least 1
     * @return The outcome
     */
    @AuraEnabled
    public static ActionOutcome creditBudget(Id registrationId, String limitType, Integer amount) {
        requireOperate();
        if (amount == null || amount < 1) {
            throw auraError(AgentGovConstants.ERR_INVALID_CREDIT);
        }
        if (!AgentGovConstants.VALID_LIMIT_TYPES.contains(limitType)) {
            throw auraError(AgentGovConstants.ERR_INVALID_LIMIT_TYPE + limitType);
        }
        List<Id> requested = new List<Id>{ registrationId };
        Map<Id, AgentGov_Registration__c> targets = visibleRegistrations(requested);
        AgentGovRequestContext.begin(null);
        Savepoint savepoint = Database.setSavepoint();
        try {
            if (targets.isEmpty()) {
                return outcomes(requested, new Map<Id, String>())[0];
            }
            // Crediting nothing first takes the lock on today's budget row and reports its usage,
            // so the amount the real credit removes is exact even when usage stops at zero.
            AgentGovBudgetManager.BudgetResult before = AgentGovBudgetManager.creditBudget(
                registrationId,
                limitType,
                0
            );
            AgentGovBudgetManager.BudgetResult after = AgentGovBudgetManager.creditBudget(
                registrationId,
                limitType,
                amount
            );
            Integer credited = (remainingOf(after, limitType) - remainingOf(before, limitType)).intValue();
            if (credited == 0) {
                Database.rollback(savepoint);
                return refused(
                    registrationId,
                    'Nothing was credited: no ' +
                        AgentGovConstants.LIMIT_LABELS.get(limitType) +
                        ' have been used today.'
                );
            }
            String summary = 'Credited ' + credited + ' ' + unitsOf(limitType, credited) + ' to today\'s budget';
            String details = summary;
            if (credited < amount) {
                summary += ', bringing its ' + SINGULAR_LIMIT_LABELS.get(limitType) + ' usage to zero';
                details = summary + ' (a credit of ' + amount + ' was requested)';
            }
            writeAudit(
                new List<AgentGov_Action_Log__c>{
                    adminRow(
                        registrationId,
                        details + '. Status is now ' + after.budgetStatus + '. Done from the console.'
                    )
                }
            );
            return outcomes(requested, new Map<Id, String>{ registrationId => summary + '.' })[0];
        } catch (Exception e) {
            return failed(savepoint, requested, 'The budget could not be credited.', e)[0];
        }
    }

    /**
     * @description Issues a replacement API key for an agent. The previous key stops working
     *              at once. The new key is returned this one time; only its hash is stored, and
     *              the audit row records only its prefix.
     * @param registrationId The agent
     * @return The new key, or the reason it could not be issued
     */
    @AuraEnabled
    public static IssuedKey rotateApiKey(Id registrationId) {
        if (!FeatureManagement.checkPermission(AgentGovConstants.CUSTOM_PERMISSION_MANAGE_KEYS)) {
            throw auraError(AgentGovConstants.ERR_MANAGE_KEYS_PERMISSION);
        }
        List<Id> requested = new List<Id>{ registrationId };
        Map<Id, AgentGov_Registration__c> targets = visibleRegistrations(requested);
        AgentGovRequestContext.begin(null);
        IssuedKey issued = new IssuedKey();
        Savepoint savepoint = Database.setSavepoint();
        try {
            if (targets.isEmpty()) {
                issued.success = false;
                issued.message = outcomes(requested, new Map<Id, String>())[0].message;
                return issued;
            }
            String apiKey = AgentGovRegistryService.issueApiKey(registrationId);
            String prefix = AgentGovRestAuth.keyPrefix(apiKey);
            writeAudit(
                new List<AgentGov_Action_Log__c>{
                    adminRow(registrationId, 'API key replaced from the console. New key prefix: ' + prefix + '.')
                }
            );
            issued.success = true;
            issued.apiKey = apiKey;
            issued.apiKeyPrefix = prefix;
            issued.rotatedAt = DateTime.now();
            return issued;
        } catch (Exception e) {
            issued.success = false;
            issued.message = failed(savepoint, requested, 'The API key could not be replaced.', e)[0].message;
            return issued;
        }
    }

    /**
     * @description Schedules the three background jobs to run as the current user, in that
     *              user's time zone, replacing the AgentGov jobs already scheduled; see
     *              AgentGovJobScheduler.scheduleAll for which jobs it replaces.
     * @return The outcome
     */
    @AuraEnabled
    public static ActionOutcome scheduleJobs() {
        requireOperate();
        AgentGovRequestContext.begin(null);
        Savepoint savepoint = Database.setSavepoint();
        List<Id> none = new List<Id>{ null };
        try {
            AgentGovJobScheduler.scheduleAll();
            writeAudit(
                new List<AgentGov_Action_Log__c>{ adminRow(null, 'Background jobs scheduled from the console.') }
            );
            return outcomes(
                none,
                new Map<Id, String>{
                    null => 'The three background jobs are scheduled to run as you, in your time zone, replacing those already scheduled.'
                }
            )[0];
        } catch (Exception e) {
            return failed(savepoint, none, 'The background jobs could not be scheduled.', e)[0];
        }
    }

    /**
     * @description Reports the setup state the console's checklist shows: whether governance
     *              and real-time events are on, whether alerts reach anyone, the session idle
     *              window in force, the jobs and their next runs, and any policy
     *              misconfiguration.
     * @return The setup state
     */
    @AuraEnabled(cacheable=true)
    public static SetupStatus getSetupStatus() {
        requireOperate();
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        SetupStatus status = new SetupStatus();
        status.governanceEnabled = AgentGovSelector.isFrameworkEnabled();
        status.realTimeEventsEnabled = AgentGovSelector.isRealTimeEventsEnabled();
        status.adminEmailConfigured = String.isNotBlank(settings.Admin_Notification_Email__c);
        status.notifyAgentOwners = settings.Notify_Agent_Owners__c == true;
        status.sessionIdleMinutes = idleMinutesInForce(settings.Session_Idle_Minutes__c);
        status.jobs = AgentGovJobScheduler.getJobStatus();
        status.policyProblems = AgentGovPolicyEngine.validatePolicies();
        return status;
    }

    // --- Private helpers ---

    private static void requireOperate() {
        if (!FeatureManagement.checkPermission(AgentGovConstants.CUSTOM_PERMISSION_OPERATE_AGENTS)) {
            throw auraError(AgentGovConstants.ERR_OPERATE_PERMISSION);
        }
    }

    private static Set<Id> requireSelection(List<Id> recordIds) {
        Set<Id> requested = new Set<Id>();
        if (recordIds != null) {
            for (Id recordId : recordIds) {
                if (recordId != null) {
                    requested.add(recordId);
                }
            }
        }
        if (requested.isEmpty()) {
            throw auraError(AgentGovConstants.ERR_NOTHING_SELECTED);
        }
        if (requested.size() > AgentGovConstants.MAX_ADMIN_BATCH) {
            throw auraError(
                String.format(
                    AgentGovConstants.ERR_ADMIN_BATCH_TOO_LARGE,
                    new List<String>{ String.valueOf(AgentGovConstants.MAX_ADMIN_BATCH) }
                )
            );
        }
        return requested;
    }

    // Read in user mode, so a person can only act on agents they are allowed to see.
    private static Map<Id, AgentGov_Registration__c> visibleRegistrations(List<Id> registrationIds) {
        Set<Id> requested = requireSelection(registrationIds);
        try {
            return new Map<Id, AgentGov_Registration__c>(
                [
                    SELECT Id, Agent_Name__c, Status__c, Circuit_Breaker_State__c
                    FROM AgentGov_Registration__c
                    WHERE Id IN :requested
                    WITH USER_MODE
                ]
            );
        } catch (Exception e) {
            throw auraError(AgentGovConstants.ERR_NO_RECORD_ACCESS);
        }
    }

    private static Map<Id, AgentGov_Registration__c> withStatusOtherThan(
        Map<Id, AgentGov_Registration__c> registrations,
        String status
    ) {
        Map<Id, AgentGov_Registration__c> others = new Map<Id, AgentGov_Registration__c>();
        for (AgentGov_Registration__c registration : registrations.values()) {
            if (registration.Status__c != status) {
                others.put(registration.Id, registration);
            }
        }
        return others;
    }

    private static Map<Id, String> describeEach(List<AgentGov_Registration__c> targets, String prefix, String field) {
        Map<Id, String> details = new Map<Id, String>();
        for (AgentGov_Registration__c target : targets) {
            details.put(target.Id, prefix + target.get(field) + '.');
        }
        return details;
    }

    // All or nothing: a change must not stand without its audit row.
    private static void audit(Map<Id, String> detailsByAgent) {
        List<AgentGov_Action_Log__c> rows = new List<AgentGov_Action_Log__c>();
        for (Id agentId : detailsByAgent.keySet()) {
            rows.add(adminRow(agentId, detailsByAgent.get(agentId)));
        }
        writeAudit(rows);
    }

    private static void writeAudit(List<AgentGov_Action_Log__c> rows) {
        AgentGovDml.insertRecords(rows, true);
        if (failureAfterAudit != null) {
            throw failureAfterAudit;
        }
    }

    // The person who acted is the row's CreatedById, so no name is copied into the text.
    private static AgentGov_Action_Log__c adminRow(Id agentId, String details) {
        return new AgentGov_Action_Log__c(
            Agent_Registration__c = agentId,
            Action_Type__c = AgentGovConstants.ACTION_ADMIN,
            Status__c = AgentGovConstants.ACTION_SUCCESS,
            Timestamp__c = DateTime.now(),
            Correlation_Id__c = AgentGovRequestContext.getCorrelationId(),
            Details__c = details
        );
    }

    private static Map<Id, String> sameMessage(Set<Id> reached, String message) {
        Map<Id, String> messages = new Map<Id, String>();
        for (Id recordId : reached) {
            messages.put(recordId, message);
        }
        return messages;
    }

    // The records the action reached get the first message when it changed them and the
    // second when they were already in the state it asks for.
    private static Map<Id, String> changedOrNot(
        Set<Id> reached,
        Set<Id> changed,
        String changedMessage,
        String unchangedMessage
    ) {
        Map<Id, String> messages = new Map<Id, String>();
        for (Id recordId : reached) {
            messages.put(recordId, changed.contains(recordId) ? changedMessage : unchangedMessage);
        }
        return messages;
    }

    // A requested record with no message is one the user cannot see.
    private static List<ActionOutcome> outcomes(List<Id> requested, Map<Id, String> messages) {
        List<ActionOutcome> results = new List<ActionOutcome>();
        for (Id recordId : requested) {
            ActionOutcome outcome = new ActionOutcome();
            outcome.recordId = recordId;
            outcome.success = messages.containsKey(recordId);
            outcome.message = outcome.success ? messages.get(recordId) : AgentGovConstants.ERR_NO_RECORD_ACCESS;
            results.add(outcome);
        }
        return results;
    }

    private static ActionOutcome refused(Id recordId, String message) {
        ActionOutcome outcome = new ActionOutcome();
        outcome.recordId = recordId;
        outcome.success = false;
        outcome.message = message;
        return outcome;
    }

    private static List<ActionOutcome> failed(
        Savepoint savepoint,
        List<Id> requested,
        String summary,
        Exception cause
    ) {
        Database.rollback(savepoint);
        String shown;
        if (cause instanceof AgentGovException) {
            // Framework messages are written for people and are shown as they are.
            shown = cause.getMessage();
        } else {
            // Anything else is unexpected: the detail goes to the action log, not the screen.
            AgentGovTriggerHandler.recordFrameworkEvent(
                null,
                AgentGovConstants.ACTION_FAILURE,
                summary,
                cause.getTypeName() + ': ' + cause.getMessage() + '\n' + cause.getStackTraceString()
            );
            shown = summary + ' The details are in the AgentGov action log.';
        }
        List<ActionOutcome> results = new List<ActionOutcome>();
        for (Id recordId : requested) {
            results.add(refused(recordId, shown));
        }
        return results;
    }

    private static Decimal remainingOf(AgentGovBudgetManager.BudgetResult budget, String limitType) {
        if (limitType == AgentGovConstants.LIMIT_API_CALLS) {
            return budget.apiCallsRemaining;
        }
        if (limitType == AgentGovConstants.LIMIT_SOQL_QUERIES) {
            return budget.soqlQueriesRemaining;
        }
        return budget.dmlOperationsRemaining;
    }

    private static String unitsOf(String limitType, Integer count) {
        return count == 1 ? SINGULAR_LIMIT_LABELS.get(limitType) : AgentGovConstants.LIMIT_LABELS.get(limitType);
    }

    // The session tracker treats a value outside 1 to 1440 as the default, so the checklist
    // shows the window in force rather than the raw setting.
    private static Integer idleMinutesInForce(Decimal configured) {
        if (configured == null || configured < 1 || configured > AgentGovConstants.MAX_SESSION_IDLE_MINUTES) {
            return AgentGovConstants.DEFAULT_SESSION_IDLE_MINUTES;
        }
        return configured.intValue();
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        // AuraHandledException hides its constructor message from clients unless it is set explicitly.
        error.setMessage(message);
        return error;
    }
}
