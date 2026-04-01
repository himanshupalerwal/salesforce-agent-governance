/**
 * @description Service layer for managing AI agent registrations and sessions.
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovRegistryService {

    /**
     * @description Registers a new AI agent in the framework.
     * @param agentName Display name of the agent
     * @param agentType Type of agent (use AgentGovConstants.AGENT_TYPE_*)
     * @param description Optional description
     * @param apiKey Optional API key for external agents
     * @param ownerEmail Contact email for the agent owner
     * @return The created AgentGov_Registration__c record
     */
    public static AgentGov_Registration__c registerAgent(String agentName, String agentType, String description, String apiKey, String ownerEmail) {
        // Validate inputs
        if (String.isBlank(agentName)) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_INVALID_AGENT_NAME);
        }
        if (!AgentGovConstants.VALID_AGENT_TYPES.contains(agentType)) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_INVALID_AGENT_TYPE);
        }

        AgentGov_Settings__c settings = AgentGovSelector.getSettings();

        AgentGov_Registration__c registration = new AgentGov_Registration__c(
            Agent_Name__c = agentName,
            Agent_Type__c = agentType,
            Status__c = AgentGovConstants.STATUS_INACTIVE,
            Description__c = description,
            API_Key__c = apiKey,
            Owner_Email__c = ownerEmail,
            Priority__c = settings.Default_Agent_Priority__c != null ? settings.Default_Agent_Priority__c : AgentGovConstants.DEFAULT_AGENT_PRIORITY,
            Daily_API_Budget__c = AgentGovConstants.DEFAULT_API_BUDGET,
            Daily_SOQL_Budget__c = AgentGovConstants.DEFAULT_SOQL_BUDGET,
            Daily_DML_Budget__c = AgentGovConstants.DEFAULT_DML_BUDGET,
            Circuit_Breaker_State__c = AgentGovConstants.CB_CLOSED,
            Failure_Count__c = 0
        );
        insert registration;
        return registration;
    }

    /**
     * @description Activates a registered agent, making it eligible to perform actions.
     * @param registrationId The agent registration record ID
     * @return The updated registration record
     */
    public static AgentGov_Registration__c activateAgent(Id registrationId) {
        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById(registrationId);
        if (reg == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.AGENT_NOT_FOUND, AgentGovConstants.ERR_AGENT_NOT_FOUND);
        }

        // Check max concurrent agents
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        Integer maxConcurrent = settings.Max_Concurrent_Agents__c != null
            ? (Integer) settings.Max_Concurrent_Agents__c
            : AgentGovConstants.DEFAULT_MAX_CONCURRENT_AGENTS;

        if (reg.Status__c != AgentGovConstants.STATUS_ACTIVE) {
            Integer activeCount = AgentGovSelector.getActiveAgentCount();
            if (activeCount >= maxConcurrent) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.MAX_CONCURRENT_AGENTS,
                    AgentGovConstants.ERR_MAX_CONCURRENT_AGENTS
                );
            }
        }

        reg.Status__c = AgentGovConstants.STATUS_ACTIVE;
        reg.Last_Active__c = DateTime.now();
        update reg;
        AgentGovSelector.clearCache();
        return reg;
    }

    /**
     * @description Deactivates an agent.
     * @param registrationId The agent registration record ID
     * @return The updated registration record
     */
    public static AgentGov_Registration__c deactivateAgent(Id registrationId) {
        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById(registrationId);
        if (reg == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.AGENT_NOT_FOUND, AgentGovConstants.ERR_AGENT_NOT_FOUND);
        }
        reg.Status__c = AgentGovConstants.STATUS_INACTIVE;
        update reg;

        // End any active sessions
        AgentGov_Session__c activeSession = AgentGovSelector.getActiveSession(registrationId);
        if (activeSession != null) {
            activeSession.Status__c = AgentGovConstants.SESSION_TERMINATED;
            activeSession.Session_End__c = DateTime.now();
            update activeSession;
        }
        AgentGovSelector.clearCache();
        return reg;
    }

    /**
     * @description Starts a new session for an active agent.
     * @param registrationId The agent registration record ID
     * @return The created session record
     */
    public static AgentGov_Session__c startSession(Id registrationId) {
        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById(registrationId);
        if (reg == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.AGENT_NOT_FOUND, AgentGovConstants.ERR_AGENT_NOT_FOUND);
        }
        if (reg.Status__c != AgentGovConstants.STATUS_ACTIVE) {
            throw new AgentGovException(AgentGovException.ErrorCode.AGENT_NOT_ACTIVE, AgentGovConstants.ERR_AGENT_NOT_ACTIVE);
        }

        // Update last active
        reg.Last_Active__c = DateTime.now();
        update reg;

        AgentGov_Session__c session = new AgentGov_Session__c(
            Agent_Registration__c = registrationId,
            Session_Start__c = DateTime.now(),
            Status__c = AgentGovConstants.SESSION_ACTIVE,
            API_Calls_Used__c = 0,
            SOQL_Queries_Used__c = 0,
            DML_Statements_Used__c = 0,
            Actions_Count__c = 0
        );
        insert session;
        return session;
    }

    /**
     * @description Ends an active session for an agent.
     * @param sessionId The session record ID
     * @return The updated session record
     */
    public static AgentGov_Session__c endSession(Id sessionId) {
        List<AgentGov_Session__c> sessions = [
            SELECT Id, Agent_Registration__c, Status__c, Session_Start__c,
                   API_Calls_Used__c, SOQL_Queries_Used__c, DML_Statements_Used__c, Actions_Count__c
            FROM AgentGov_Session__c
            WHERE Id = :sessionId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        if (sessions.isEmpty()) {
            throw new AgentGovException(AgentGovException.ErrorCode.AGENT_NOT_FOUND, AgentGovConstants.ERR_SESSION_NOT_ACTIVE);
        }
        AgentGov_Session__c session = sessions[0];
        session.Status__c = AgentGovConstants.SESSION_COMPLETED;
        session.Session_End__c = DateTime.now();
        update session;
        return session;
    }

    /**
     * @description Gets agent details by ID.
     * @param registrationId The agent registration record ID
     * @return The registration record or null
     */
    public static AgentGov_Registration__c getAgent(Id registrationId) {
        return AgentGovSelector.getRegistrationById(registrationId);
    }
}
