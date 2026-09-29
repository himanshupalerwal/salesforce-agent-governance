/**
 * @description Service layer for agent registrations, credentials, and sessions.
 *
 *              Security posture: inherited sharing. Reads go through AgentGovSelector and
 *              writes through AgentGovDml, both of which run in system mode, so an
 *              integration user can register itself without holding access to AgentGov objects.
 */
public inherited sharing class AgentGovRegistryService {
    /**
     * @description Registers a new agent. New agents start Inactive; call activateAgent to enable them.
     *              When an API key is supplied only its hash and identifying prefix are stored.
     * @param agentName Display name of the agent
     * @param agentType One of the AgentGovConstants.AGENT_TYPE_* values
     * @param description Optional description
     * @param apiKey Optional plaintext API key chosen by the caller; pass null to issue one later with issueApiKey
     * @param ownerEmail Contact email for the agent owner
     * @return The created registration as saved, including its registration number
     * @throws AgentGovException INVALID_INPUT for a blank name, an unknown type, a key that is too short or already in use, or a value the database rejects, such as a malformed owner email
     */
    public static AgentGov_Registration__c registerAgent(
        String agentName,
        String agentType,
        String description,
        String apiKey,
        String ownerEmail
    ) {
        if (String.isBlank(agentName)) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                AgentGovConstants.ERR_INVALID_AGENT_NAME
            );
        }
        if (!AgentGovConstants.VALID_AGENT_TYPES.contains(agentType)) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                AgentGovConstants.ERR_INVALID_AGENT_TYPE
            );
        }

        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        AgentGov_Registration__c registration = new AgentGov_Registration__c(
            Agent_Name__c = agentName,
            Agent_Type__c = agentType,
            Status__c = AgentGovConstants.STATUS_INACTIVE,
            Description__c = description,
            Owner_Email__c = ownerEmail,
            Priority__c = settings.Default_Agent_Priority__c != null
                ? settings.Default_Agent_Priority__c
                : AgentGovConstants.DEFAULT_AGENT_PRIORITY,
            // Taken from AgentGov_Limit_Config__mdt when configured, so an administrator who
            // changes the default daily budget sees it applied to newly registered agents and
            // not only to budget rows created for agents that have none.
            Daily_API_Budget__c = AgentGovBudgetManager.defaultAllocation(
                AgentGovConstants.LIMIT_API_CALLS,
                AgentGovConstants.DEFAULT_API_BUDGET
            ),
            Daily_SOQL_Budget__c = AgentGovBudgetManager.defaultAllocation(
                AgentGovConstants.LIMIT_SOQL_QUERIES,
                AgentGovConstants.DEFAULT_SOQL_BUDGET
            ),
            Daily_DML_Budget__c = AgentGovBudgetManager.defaultAllocation(
                AgentGovConstants.LIMIT_DML_OPERATIONS,
                AgentGovConstants.DEFAULT_DML_BUDGET
            ),
            Circuit_Breaker_State__c = AgentGovConstants.CB_CLOSED,
            Failure_Count__c = 0
        );
        if (String.isNotBlank(apiKey)) {
            AgentGovRestAuth.requireUsableKey(apiKey);
            AgentGovRestAuth.applyKey(registration, apiKey);
        }
        try {
            AgentGovDml.insertRecord(registration);
        } catch (DmlException e) {
            // API_Key_Hash__c is unique, so a key already in use fails the insert. That is a
            // caller input error, not an internal one. The message deliberately does not say
            // whether the key exists: /register needs no credential, so distinguishing the two
            // cases would turn it into an oracle for probing keys.
            if (AgentGovDml.isDuplicateValueFailure(e)) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.INVALID_INPUT,
                    AgentGovConstants.ERR_REGISTRATION_REJECTED
                );
            }
            // A value the database rejects, such as a malformed owner email, is the caller's
            // input to correct, so it is named rather than reported as an internal failure.
            if (AgentGovDml.isRejectedValueFailure(e)) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.INVALID_INPUT,
                    String.format(
                        AgentGovConstants.ERR_REGISTRATION_INVALID_VALUE,
                        new List<String>{ rejectedFieldLabels(e) }
                    )
                );
            }
            throw e;
        }
        // The insert assigns the registration number, which the in-memory record does not
        // show, so the saved row is read back for callers that report it.
        return AgentGovSelector.getRegistrationById(registration.Id);
    }

    private static String rejectedFieldLabels(DmlException failure) {
        Map<String, Schema.SObjectField> fields = Schema.SObjectType.AgentGov_Registration__c.fields.getMap();
        List<String> labels = new List<String>();
        for (Integer i = 0; i < failure.getNumDml(); i++) {
            for (String fieldName : failure.getDmlFieldNames(i)) {
                Schema.SObjectField field = fields.get(fieldName);
                String label = field == null ? fieldName : field.getDescribe().getLabel();
                if (!labels.contains(label)) {
                    labels.add(label);
                }
            }
        }
        return labels.isEmpty() ? 'a field' : String.join(labels, ', ');
    }

    /**
     * @description Issues a new random API key for an agent, replacing any previous key.
     *              The returned plaintext is the only copy; hand it to the agent immediately.
     * @param registrationId The agent registration Id
     * @return The new plaintext key
     * @throws AgentGovException AGENT_NOT_FOUND when the registration does not exist
     */
    public static String issueApiKey(Id registrationId) {
        AgentGov_Registration__c registration = requireRegistration(registrationId);
        String apiKey = AgentGovRestAuth.generateKey();
        AgentGovRestAuth.applyKey(registration, apiKey);
        AgentGovDml.updateRecord(registration);
        AgentGovSelector.cacheRegistration(registration);
        return apiKey;
    }

    /**
     * @description Binds a Salesforce user to a registration so the user's OAuth identity
     *              authenticates REST calls without an API key. Intended for Agentforce Agent
     *              Users and External Client App integration users.
     * @param registrationId The agent registration Id
     * @param userId The user to bind, or null to remove the binding
     * @return The updated registration
     * @throws AgentGovException AGENT_NOT_FOUND when the registration does not exist
     */
    public static AgentGov_Registration__c bindAgentUser(Id registrationId, Id userId) {
        AgentGov_Registration__c registration = requireRegistration(registrationId);
        registration.Agent_User__c = userId;
        AgentGovDml.updateRecord(registration);
        AgentGovSelector.cacheRegistration(registration);
        return registration;
    }

    /**
     * @description Activates an agent, subject to the org's concurrent-agent limit.
     * @param registrationId The agent registration Id
     * @return The updated registration
     * @throws AgentGovException AGENT_NOT_FOUND or MAX_CONCURRENT_AGENTS
     */
    public static AgentGov_Registration__c activateAgent(Id registrationId) {
        AgentGov_Registration__c registration = requireRegistration(registrationId);
        if (registration.Status__c != AgentGovConstants.STATUS_ACTIVE) {
            AgentGov_Settings__c settings = AgentGovSelector.getSettings();
            Integer maxConcurrent = settings.Max_Concurrent_Agents__c != null
                ? (Integer) settings.Max_Concurrent_Agents__c
                : AgentGovConstants.DEFAULT_MAX_CONCURRENT_AGENTS;
            if (AgentGovSelector.getActiveAgentCount() >= maxConcurrent) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.MAX_CONCURRENT_AGENTS,
                    AgentGovConstants.ERR_MAX_CONCURRENT_AGENTS
                );
            }
        }
        registration.Status__c = AgentGovConstants.STATUS_ACTIVE;
        registration.Last_Active__c = DateTime.now();
        AgentGovDml.updateRecord(registration);
        AgentGovSelector.cacheRegistration(registration);
        return registration;
    }

    /**
     * @description Activates several agents at once, subject to the org's concurrent-agent
     *              limit applied to the batch as a whole. Agents that are already active are
     *              left as they are.
     * @param registrationIds Agents to activate
     * @return The registrations that were found
     * @throws AgentGovException MAX_CONCURRENT_AGENTS when the batch would exceed the limit
     */
    public static List<AgentGov_Registration__c> activateAgents(Set<Id> registrationIds) {
        Map<Id, AgentGov_Registration__c> found = AgentGovSelector.getRegistrationsForUpdate(registrationIds);
        List<AgentGov_Registration__c> toActivate = new List<AgentGov_Registration__c>();
        for (AgentGov_Registration__c registration : found.values()) {
            if (registration.Status__c != AgentGovConstants.STATUS_ACTIVE) {
                toActivate.add(registration);
            }
        }
        if (toActivate.isEmpty()) {
            return found.values();
        }
        // Checked for the batch as a whole: checking agent by agent would let one batch
        // activate past the limit.
        if (AgentGovSelector.getActiveAgentCount() + toActivate.size() > maxConcurrentAgents()) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.MAX_CONCURRENT_AGENTS,
                AgentGovConstants.ERR_MAX_CONCURRENT_AGENTS
            );
        }
        DateTime now = DateTime.now();
        for (AgentGov_Registration__c registration : toActivate) {
            registration.Status__c = AgentGovConstants.STATUS_ACTIVE;
            registration.Last_Active__c = now;
        }
        persist(toActivate);
        return found.values();
    }

    /**
     * @description Deactivates an agent and ends all of its active sessions.
     * @param registrationId The agent registration Id
     * @return The updated registration
     * @throws AgentGovException AGENT_NOT_FOUND when the registration does not exist
     */
    public static AgentGov_Registration__c deactivateAgent(Id registrationId) {
        requireRegistration(registrationId);
        return deactivateAgents(new Set<Id>{ registrationId })[0];
    }

    /**
     * @description Deactivates several agents at once and ends all of their active sessions,
     *              including duplicates left by releases before v1.3. This is the per-agent
     *              kill switch: a deactivated agent is refused on every entry point.
     * @param registrationIds Agents to deactivate
     * @return The registrations that were found
     */
    public static List<AgentGov_Registration__c> deactivateAgents(Set<Id> registrationIds) {
        Map<Id, AgentGov_Registration__c> found = AgentGovSelector.getRegistrationsForUpdate(registrationIds);
        for (AgentGov_Registration__c registration : found.values()) {
            registration.Status__c = AgentGovConstants.STATUS_INACTIVE;
        }
        persist(found.values());
        AgentGovSessionTracker.endAllForAgents(found.keySet(), AgentGovConstants.SESSION_END_DEACTIVATED);
        return found.values();
    }

    /**
     * @description Ends sessions on an administrator's instruction, for example a run that
     *              should not continue. The agent's next governed call opens a new session.
     * @param sessionIds Sessions to end
     * @return The sessions that were ended
     */
    public static List<AgentGov_Session__c> terminateSessions(Set<Id> sessionIds) {
        return AgentGovSessionTracker.endSessions(
            sessionIds,
            AgentGovConstants.SESSION_TERMINATED,
            AgentGovConstants.SESSION_END_ADMINISTRATOR
        );
    }

    /**
     * @description Starts a new session for an active agent, ending its current one first.
     *              Sessions open and close automatically with governed activity, so this is
     *              only needed by callers that want an explicit boundary between runs.
     * @param registrationId The agent registration Id
     * @return The created session
     * @throws AgentGovException AGENT_NOT_FOUND or AGENT_NOT_ACTIVE
     */
    public static AgentGov_Session__c startSession(Id registrationId) {
        AgentGov_Registration__c registration = requireRegistration(registrationId);
        if (registration.Status__c != AgentGovConstants.STATUS_ACTIVE) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.AGENT_NOT_ACTIVE,
                AgentGovConstants.ERR_AGENT_NOT_ACTIVE
            );
        }
        registration.Last_Active__c = DateTime.now();
        AgentGovDml.updateRecord(registration);
        AgentGovSelector.cacheRegistration(registration);
        return AgentGovSessionTracker.startSession(registrationId);
    }

    /**
     * @description Ends a session.
     * @param sessionId The session Id
     * @return The updated session
     * @throws AgentGovException AGENT_NOT_FOUND when the session does not exist
     */
    public static AgentGov_Session__c endSession(Id sessionId) {
        // Guarded below: re-ending a Completed or Terminated session used to overwrite its
        // end time, rewriting history for a session that had already finished.
        AgentGov_Session__c session = AgentGovSelector.getSessionById(sessionId);
        if (session == null) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.AGENT_NOT_FOUND,
                AgentGovConstants.ERR_SESSION_NOT_ACTIVE
            );
        }
        if (session.Status__c != AgentGovConstants.SESSION_ACTIVE) {
            // Already finished. Returning it unchanged keeps the original end time, which is
            // the historical fact; rewriting it would move when the session actually ended.
            return session;
        }
        AgentGovSessionTracker.endSessions(
            new Set<Id>{ sessionId },
            AgentGovConstants.SESSION_COMPLETED,
            AgentGovConstants.SESSION_END_CALLER
        );
        return AgentGovSelector.getSessionById(sessionId);
    }

    /**
     * @description Reads an agent registration.
     * @param registrationId The agent registration Id
     * @return The registration, or null when it does not exist
     */
    public static AgentGov_Registration__c getAgent(Id registrationId) {
        return AgentGovSelector.getRegistrationById(registrationId);
    }

    private static Integer maxConcurrentAgents() {
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        return settings.Max_Concurrent_Agents__c != null
            ? (Integer) settings.Max_Concurrent_Agents__c
            : AgentGovConstants.DEFAULT_MAX_CONCURRENT_AGENTS;
    }

    private static void persist(List<AgentGov_Registration__c> registrations) {
        if (registrations.isEmpty()) {
            return;
        }
        AgentGovDml.assertAllSucceeded(AgentGovDml.updateRecords(registrations, false), 'Registration update');
        for (AgentGov_Registration__c registration : registrations) {
            AgentGovSelector.cacheRegistration(registration);
        }
    }

    private static AgentGov_Registration__c requireRegistration(Id registrationId) {
        AgentGov_Registration__c registration = AgentGovSelector.getRegistrationById(registrationId);
        if (registration == null) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.AGENT_NOT_FOUND,
                AgentGovConstants.ERR_AGENT_NOT_FOUND
            );
        }
        return registration;
    }
}
