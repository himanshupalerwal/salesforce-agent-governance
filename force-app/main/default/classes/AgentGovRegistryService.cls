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
     * @return The created registration
     * @throws AgentGovException INVALID_INPUT for a blank name or unknown type
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
            throw e;
        }
        AgentGovSelector.cacheRegistration(registration);
        return registration;
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
     * @description Deactivates an agent and terminates its active session, if any.
     * @param registrationId The agent registration Id
     * @return The updated registration
     * @throws AgentGovException AGENT_NOT_FOUND when the registration does not exist
     */
    public static AgentGov_Registration__c deactivateAgent(Id registrationId) {
        AgentGov_Registration__c registration = requireRegistration(registrationId);
        registration.Status__c = AgentGovConstants.STATUS_INACTIVE;
        AgentGovDml.updateRecord(registration);
        AgentGovSelector.cacheRegistration(registration);

        AgentGov_Session__c activeSession = AgentGovSelector.getActiveSession(registrationId);
        if (activeSession != null) {
            activeSession.Status__c = AgentGovConstants.SESSION_TERMINATED;
            activeSession.Session_End__c = DateTime.now();
            AgentGovDml.updateRecord(activeSession);
        }
        return registration;
    }

    /**
     * @description Starts a session for an active agent.
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

        AgentGov_Session__c session = new AgentGov_Session__c(
            Agent_Registration__c = registrationId,
            Session_Start__c = DateTime.now(),
            Status__c = AgentGovConstants.SESSION_ACTIVE,
            API_Calls_Used__c = 0,
            SOQL_Queries_Used__c = 0,
            DML_Statements_Used__c = 0,
            Actions_Count__c = 0
        );
        AgentGovDml.insertRecord(session);
        return session;
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
        session.Status__c = AgentGovConstants.SESSION_COMPLETED;
        session.Session_End__c = DateTime.now();
        AgentGovDml.updateRecord(session);
        return session;
    }

    /**
     * @description Reads an agent registration.
     * @param registrationId The agent registration Id
     * @return The registration, or null when it does not exist
     */
    public static AgentGov_Registration__c getAgent(Id registrationId) {
        return AgentGovSelector.getRegistrationById(registrationId);
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
