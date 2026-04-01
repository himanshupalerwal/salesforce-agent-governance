/**
 * @description Test data factory for the AgentGov framework.
 *              Provides reusable methods to create test data for all custom objects.
 * @author Himanshu Palerwal
 */
@IsTest
public class AgentGovTestDataFactory {

    /** @description Creates and inserts an agent registration with default values. */
    public static AgentGov_Registration__c createRegistration(String agentName, String agentType, Boolean doInsert) {
        AgentGov_Registration__c reg = new AgentGov_Registration__c(
            Agent_Name__c = agentName,
            Agent_Type__c = agentType,
            Status__c = AgentGovConstants.STATUS_ACTIVE,
            Priority__c = AgentGovConstants.DEFAULT_AGENT_PRIORITY,
            Daily_API_Budget__c = AgentGovConstants.DEFAULT_API_BUDGET,
            Daily_SOQL_Budget__c = AgentGovConstants.DEFAULT_SOQL_BUDGET,
            Daily_DML_Budget__c = AgentGovConstants.DEFAULT_DML_BUDGET,
            Circuit_Breaker_State__c = AgentGovConstants.CB_CLOSED,
            Failure_Count__c = 0,
            Owner_Email__c = 'test@agentgov.test'
        );
        if (doInsert) {
            insert reg;
        }
        return reg;
    }

    /** @description Creates an agent registration with a specific API key. */
    public static AgentGov_Registration__c createRegistrationWithApiKey(String agentName, String agentType, String apiKey) {
        AgentGov_Registration__c reg = createRegistration(agentName, agentType, false);
        reg.API_Key__c = apiKey;
        insert reg;
        return reg;
    }

    /** @description Creates multiple agent registrations. */
    public static List<AgentGov_Registration__c> createRegistrations(Integer count, String agentType) {
        List<AgentGov_Registration__c> registrations = new List<AgentGov_Registration__c>();
        for (Integer i = 0; i < count; i++) {
            registrations.add(createRegistration('Test Agent ' + i, agentType, false));
            registrations[i].API_Key__c = 'test-key-' + i;
        }
        insert registrations;
        return registrations;
    }

    /** @description Creates a session for an agent. */
    public static AgentGov_Session__c createSession(Id registrationId, Boolean doInsert) {
        AgentGov_Session__c session = new AgentGov_Session__c(
            Agent_Registration__c = registrationId,
            Session_Start__c = DateTime.now(),
            Status__c = AgentGovConstants.SESSION_ACTIVE,
            API_Calls_Used__c = 0,
            SOQL_Queries_Used__c = 0,
            DML_Statements_Used__c = 0,
            Actions_Count__c = 0
        );
        if (doInsert) {
            insert session;
        }
        return session;
    }

    /** @description Creates a budget for an agent for today. */
    public static AgentGov_Budget__c createBudget(Id registrationId, Boolean doInsert) {
        AgentGov_Budget__c budget = new AgentGov_Budget__c(
            Agent_Registration__c = registrationId,
            Budget_Date__c = Date.today(),
            API_Calls_Allocated__c = AgentGovConstants.DEFAULT_API_BUDGET,
            API_Calls_Consumed__c = 0,
            SOQL_Queries_Allocated__c = AgentGovConstants.DEFAULT_SOQL_BUDGET,
            SOQL_Queries_Consumed__c = 0,
            DML_Operations_Allocated__c = AgentGovConstants.DEFAULT_DML_BUDGET,
            DML_Operations_Consumed__c = 0,
            Budget_Status__c = AgentGovConstants.BUDGET_NORMAL
        );
        if (doInsert) {
            insert budget;
        }
        return budget;
    }

    /** @description Creates a budget with custom allocation. */
    public static AgentGov_Budget__c createBudgetWithAllocation(Id registrationId, Integer apiCalls, Integer soqlQueries, Integer dmlOps) {
        AgentGov_Budget__c budget = createBudget(registrationId, false);
        budget.API_Calls_Allocated__c = apiCalls;
        budget.SOQL_Queries_Allocated__c = soqlQueries;
        budget.DML_Operations_Allocated__c = dmlOps;
        insert budget;
        return budget;
    }

    /** @description Creates an action log entry. */
    public static AgentGov_Action_Log__c createActionLog(Id registrationId, Id sessionId, String actionType, String status, Boolean doInsert) {
        AgentGov_Action_Log__c log = new AgentGov_Action_Log__c(
            Agent_Registration__c = registrationId,
            Agent_Session__c = sessionId,
            Action_Type__c = actionType,
            Status__c = status,
            Timestamp__c = DateTime.now(),
            Object_Name__c = 'Account',
            Execution_Time_Ms__c = 50
        );
        if (doInsert) {
            insert log;
        }
        return log;
    }

    /** @description Creates a conflict log entry. */
    public static AgentGov_Conflict_Log__c createConflictLog(Id agent1Id, Id agent2Id, Boolean doInsert) {
        AgentGov_Conflict_Log__c conflict = new AgentGov_Conflict_Log__c(
            Agent_1__c = agent1Id,
            Agent_2__c = agent2Id,
            Record_Id__c = '001000000000001',
            Object_Name__c = 'Account',
            Conflict_Type__c = AgentGovConstants.CONFLICT_CONCURRENT_WRITE,
            Resolution__c = AgentGovConstants.RESOLUTION_AGENT1_WON,
            Severity__c = AgentGovConstants.SEVERITY_MEDIUM,
            Timestamp__c = DateTime.now()
        );
        if (doInsert) {
            insert conflict;
        }
        return conflict;
    }

    /** @description Creates org-level default settings. */
    public static AgentGov_Settings__c createSettings() {
        AgentGov_Settings__c settings = new AgentGov_Settings__c(
            Is_Enabled__c = true,
            Default_Agent_Priority__c = AgentGovConstants.DEFAULT_AGENT_PRIORITY,
            Circuit_Breaker_Failure_Threshold__c = AgentGovConstants.DEFAULT_CB_FAILURE_THRESHOLD,
            Circuit_Breaker_Cooldown_Minutes__c = AgentGovConstants.DEFAULT_CB_COOLDOWN_MINUTES,
            Log_Retention_Days__c = AgentGovConstants.DEFAULT_LOG_RETENTION_DAYS,
            Enable_Conflict_Detection__c = true,
            Enable_Real_Time_Events__c = true,
            Max_Concurrent_Agents__c = AgentGovConstants.DEFAULT_MAX_CONCURRENT_AGENTS
        );
        insert settings;
        return settings;
    }

    /** @description Creates settings with the framework disabled. */
    public static AgentGov_Settings__c createDisabledSettings() {
        AgentGov_Settings__c settings = createSettings();
        settings.Is_Enabled__c = false;
        update settings;
        return settings;
    }
}
