@IsTest
private class AgentGovSelectorTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Test Agent', 'Agentforce', true);
        AgentGovTestDataFactory.createSession(reg.Id, true);
        AgentGovTestDataFactory.createBudget(reg.Id, true);
    }

    @IsTest
    static void testGetSettings() {
        Test.startTest();
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        Test.stopTest();

        System.assertNotEquals(null, settings, 'Settings should not be null');
        System.assertEquals(true, settings.Is_Enabled__c, 'Framework should be enabled');
    }

    @IsTest
    static void testGetSettingsDefaultsWhenNoneExist() {
        delete [SELECT Id FROM AgentGov_Settings__c];
        AgentGovSelector.clearCache();

        Test.startTest();
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        Test.stopTest();

        System.assertNotEquals(null, settings, 'Should return defaults when no settings exist');
    }

    @IsTest
    static void testIsFrameworkEnabled() {
        Test.startTest();
        Boolean enabled = AgentGovSelector.isFrameworkEnabled();
        Test.stopTest();

        System.assertEquals(true, enabled, 'Framework should be enabled');
    }

    @IsTest
    static void testGetLimitConfigs() {
        Test.startTest();
        List<AgentGov_Limit_Config__mdt> configs = AgentGovSelector.getLimitConfigs();
        Test.stopTest();

        // Custom Metadata may or may not be present in test context
        System.assertNotEquals(null, configs, 'Should return a list (possibly empty)');
    }

    @IsTest
    static void testGetRegistrationById() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        Test.startTest();
        AgentGov_Registration__c result = AgentGovSelector.getRegistrationById(reg.Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should find the registration');
        System.assertEquals('Test Agent', result.Agent_Name__c, 'Agent name should match');
    }

    @IsTest
    static void testGetRegistrationByIdNull() {
        Test.startTest();
        AgentGov_Registration__c result = AgentGovSelector.getRegistrationById(null);
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for null ID');
    }

    @IsTest
    static void testGetRegistrationByApiKey() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        reg.API_Key__c = 'test-api-key-selector';
        update reg;
        AgentGovSelector.clearCache();

        Test.startTest();
        AgentGov_Registration__c result = AgentGovSelector.getRegistrationByApiKey('test-api-key-selector');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should find by API key');
    }

    @IsTest
    static void testGetRegistrationByApiKeyBlank() {
        Test.startTest();
        AgentGov_Registration__c result = AgentGovSelector.getRegistrationByApiKey('');
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for blank key');
    }

    @IsTest
    static void testGetActiveRegistrations() {
        Test.startTest();
        List<AgentGov_Registration__c> results = AgentGovSelector.getActiveRegistrations();
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should find 1 active agent');
    }

    @IsTest
    static void testGetAllRegistrations() {
        Test.startTest();
        List<AgentGov_Registration__c> results = AgentGovSelector.getAllRegistrations();
        Test.stopTest();

        System.assert(results.size() >= 1, 'Should find at least 1 registration');
    }

    @IsTest
    static void testGetTodaysBudget() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        Test.startTest();
        AgentGov_Budget__c budget = AgentGovSelector.getTodaysBudget(reg.Id);
        Test.stopTest();

        System.assertNotEquals(null, budget, 'Should find today\'s budget');
    }

    @IsTest
    static void testGetTodaysBudgetForUpdate() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        Test.startTest();
        AgentGov_Budget__c budget = AgentGovSelector.getTodaysBudgetForUpdate(reg.Id);
        Test.stopTest();

        System.assertNotEquals(null, budget, 'Should find budget with FOR UPDATE');
    }

    @IsTest
    static void testGetActiveSession() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        Test.startTest();
        AgentGov_Session__c session = AgentGovSelector.getActiveSession(reg.Id);
        Test.stopTest();

        System.assertNotEquals(null, session, 'Should find active session');
    }

    @IsTest
    static void testGetOrphanedSessions() {
        Test.startTest();
        List<AgentGov_Session__c> results = AgentGovSelector.getOrphanedSessions(0);
        Test.stopTest();

        System.assertNotEquals(null, results, 'Should return a list');
    }

    @IsTest
    static void testGetActiveAgentCount() {
        Test.startTest();
        Integer count = AgentGovSelector.getActiveAgentCount();
        Test.stopTest();

        System.assertEquals(1, count, 'Should count 1 active agent');
    }

    @IsTest
    static void testGetAllTodaysBudgets() {
        Test.startTest();
        List<AgentGov_Budget__c> budgets = AgentGovSelector.getAllTodaysBudgets();
        Test.stopTest();

        System.assertEquals(1, budgets.size(), 'Should find 1 budget for today');
    }

    @IsTest
    static void testGetRecentActionLogs() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        AgentGov_Session__c session = [SELECT Id FROM AgentGov_Session__c LIMIT 1];
        AgentGovTestDataFactory.createActionLog(reg.Id, session.Id, 'Query', 'Success', true);

        Test.startTest();
        List<AgentGov_Action_Log__c> logs = AgentGovSelector.getRecentActionLogs(reg.Id, 10);
        Test.stopTest();

        System.assertEquals(1, logs.size(), 'Should find 1 action log');
    }

    @IsTest
    static void testGetRecentConflictLogs() {
        List<AgentGov_Registration__c> agents = AgentGovTestDataFactory.createRegistrations(2, 'Custom_Apex');
        AgentGovTestDataFactory.createConflictLog(agents[0].Id, agents[1].Id, true);

        Test.startTest();
        List<AgentGov_Conflict_Log__c> conflicts = AgentGovSelector.getRecentConflictLogs(10);
        Test.stopTest();

        System.assert(conflicts.size() >= 1, 'Should find at least 1 conflict log');
    }

    @IsTest
    static void testClearCache() {
        // Just verify it doesn't throw
        Test.startTest();
        AgentGovSelector.clearCache();
        Test.stopTest();

        // Re-query after cache clear
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        System.assertNotEquals(null, settings, 'Should still return settings after cache clear');
    }

    @IsTest
    static void testGetPolicies() {
        Test.startTest();
        List<AgentGov_Policy__mdt> policies = AgentGovSelector.getPolicies();
        Test.stopTest();

        System.assertNotEquals(null, policies, 'Should return a list');
    }

    @IsTest
    static void testGetOpenAgentsPastCooldown() {
        Test.startTest();
        List<AgentGov_Registration__c> agents = AgentGovSelector.getOpenAgentsPastCooldown();
        Test.stopTest();

        System.assertNotEquals(null, agents, 'Should return a list');
    }

    @IsTest
    static void testGetHalfOpenAgentsPastCooldown() {
        Test.startTest();
        List<AgentGov_Registration__c> agents = AgentGovSelector.getHalfOpenAgentsPastCooldown();
        Test.stopTest();

        System.assertNotEquals(null, agents, 'Should return a list');
    }
}
