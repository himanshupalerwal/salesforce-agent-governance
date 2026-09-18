/**
 * @description Test data factory for the AgentGov framework.
 *              Provides reusable builders for every custom object plus a minimal-permission
 *              user for tests that must prove the framework works without object access.
 */
@IsTest
public class AgentGovTestDataFactory {
    /** @description Profile used for the restricted test user. Falls back to Standard User when absent. */
    private static final String MINIMUM_ACCESS_PROFILE = 'Minimum Access - Salesforce';

    /** @description Creates an agent registration with default values. */
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
            Owner_Email__c = 'agentgov-test@example.com'
        );
        if (doInsert) {
            insert reg;
        }
        return reg;
    }

    /** @description Creates an agent registration whose API key is stored hashed, as in production. */
    public static AgentGov_Registration__c createRegistrationWithApiKey(
        String agentName,
        String agentType,
        String apiKey
    ) {
        AgentGov_Registration__c reg = createRegistration(agentName, agentType, false);
        AgentGovRestAuth.applyKey(reg, apiKey);
        insert reg;
        return reg;
    }

    /** @description Creates an agent registration that still carries a pre-v1.2 plaintext key. */
    public static AgentGov_Registration__c createRegistrationWithLegacyKey(
        String agentName,
        String agentType,
        String apiKey
    ) {
        AgentGov_Registration__c reg = createRegistration(agentName, agentType, false);
        reg.API_Key__c = apiKey;
        insert reg;
        return reg;
    }

    /** @description Creates several agent registrations with hashed keys test-key-0, test-key-1, and so on. */
    public static List<AgentGov_Registration__c> createRegistrations(Integer count, String agentType) {
        List<AgentGov_Registration__c> registrations = new List<AgentGov_Registration__c>();
        for (Integer i = 0; i < count; i++) {
            AgentGov_Registration__c reg = createRegistration('Test Agent ' + i, agentType, false);
            AgentGovRestAuth.applyKey(reg, 'test-key-' + i);
            registrations.add(reg);
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

    /** @description Creates today's budget for an agent with the default allocations. */
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

    /** @description Creates today's budget with custom allocations. */
    public static AgentGov_Budget__c createBudgetWithAllocation(
        Id registrationId,
        Integer apiCalls,
        Integer soqlQueries,
        Integer dmlOps
    ) {
        AgentGov_Budget__c budget = createBudget(registrationId, false);
        budget.API_Calls_Allocated__c = apiCalls;
        budget.SOQL_Queries_Allocated__c = soqlQueries;
        budget.DML_Operations_Allocated__c = dmlOps;
        insert budget;
        return budget;
    }

    /** @description Creates an action log entry. */
    public static AgentGov_Action_Log__c createActionLog(
        Id registrationId,
        Id sessionId,
        String actionType,
        String status,
        Boolean doInsert
    ) {
        AgentGov_Action_Log__c entry = new AgentGov_Action_Log__c(
            Agent_Registration__c = registrationId,
            Agent_Session__c = sessionId,
            Action_Type__c = actionType,
            Status__c = status,
            Timestamp__c = DateTime.now(),
            Object_Name__c = 'Account',
            Execution_Time_Ms__c = 50
        );
        if (doInsert) {
            insert entry;
        }
        return entry;
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

    /**
     * @description Creates a user with the least-privileged standard profile available and
     *              assigns the given permission sets. Runs inside System.runAs to avoid the
     *              mixed-DML restriction between setup and non-setup objects.
     * @param permissionSetNames API names of permission sets to assign; may be empty
     * @return The inserted user
     */
    public static User createRestrictedUser(List<String> permissionSetNames) {
        List<Profile> profiles = [SELECT Id FROM Profile WHERE Name = :MINIMUM_ACCESS_PROFILE LIMIT 1];
        if (profiles.isEmpty()) {
            profiles = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        }
        String uniqueness = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User restricted = new User(
            ProfileId = profiles[0].Id,
            FirstName = 'Restricted',
            LastName = 'Agent',
            Alias = 'ragt' + uniqueness.left(4),
            Username = 'restricted.agent.' + uniqueness + '@agentgov.example',
            Email = 'restricted.agent@agentgov.example',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert restricted;
            if (permissionSetNames != null && !permissionSetNames.isEmpty()) {
                List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
                for (PermissionSet permissionSet : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames]) {
                    assignments.add(
                        new PermissionSetAssignment(AssigneeId = restricted.Id, PermissionSetId = permissionSet.Id)
                    );
                }
                insert assignments;
            }
        }
        return restricted;
    }
}
