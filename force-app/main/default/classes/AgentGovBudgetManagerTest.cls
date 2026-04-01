@IsTest
private class AgentGovBudgetManagerTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Budget Test Agent', 'Agentforce', true);
        AgentGovTestDataFactory.createBudget(reg.Id, true);
    }

    @IsTest
    static void testCheckBudget() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        Test.startTest();
        AgentGovBudgetManager.BudgetResult result = AgentGovBudgetManager.checkBudget(reg.Id);
        Test.stopTest();

        System.assertEquals(true, result.allowed, 'Should have budget');
        System.assertEquals(AgentGovConstants.BUDGET_NORMAL, result.budgetStatus);
        System.assertEquals(10000, result.apiCallsRemaining);
    }

    @IsTest
    static void testCheckBudgetNullId() {
        Test.startTest();
        try {
            AgentGovBudgetManager.checkBudget(null);
            System.assert(false, 'Should throw for null ID');
        } catch (AgentGovException e) {
            System.assertEquals(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
        }
        Test.stopTest();
    }

    @IsTest
    static void testConsumeBudget() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        Test.startTest();
        AgentGovBudgetManager.BudgetResult result = AgentGovBudgetManager.consumeBudget(
            reg.Id, AgentGovConstants.LIMIT_API_CALLS, 100
        );
        Test.stopTest();

        System.assertEquals(9900, result.apiCallsRemaining, 'Should have consumed 100 API calls');
    }

    @IsTest
    static void testConsumeBudgetSOQL() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        Test.startTest();
        AgentGovBudgetManager.BudgetResult result = AgentGovBudgetManager.consumeBudget(
            reg.Id, AgentGovConstants.LIMIT_SOQL_QUERIES, 50
        );
        Test.stopTest();

        System.assertEquals(4950, result.soqlQueriesRemaining);
    }

    @IsTest
    static void testConsumeBudgetDML() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        Test.startTest();
        AgentGovBudgetManager.BudgetResult result = AgentGovBudgetManager.consumeBudget(
            reg.Id, AgentGovConstants.LIMIT_DML_OPERATIONS, 30
        );
        Test.stopTest();

        System.assertEquals(2970, result.dmlOperationsRemaining);
    }

    @IsTest
    static void testBudgetExceeded() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        AgentGov_Budget__c budget = [SELECT Id FROM AgentGov_Budget__c WHERE Agent_Registration__c = :reg.Id LIMIT 1];
        budget.API_Calls_Consumed__c = 9999;
        update budget;

        Test.startTest();
        try {
            AgentGovBudgetManager.consumeBudget(reg.Id, AgentGovConstants.LIMIT_API_CALLS, 100);
            System.assert(false, 'Should throw for budget exceeded');
        } catch (AgentGovException e) {
            System.assert(e.getMessage().contains('API_Calls'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testAutoCreateBudget() {
        // Create agent without budget
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('No Budget Agent', 'Custom_Apex', true);

        Test.startTest();
        AgentGovBudgetManager.BudgetResult result = AgentGovBudgetManager.checkBudget(reg.Id);
        Test.stopTest();

        System.assertEquals(true, result.allowed, 'Should auto-create budget and allow');
    }

    @IsTest
    static void testGetRemainingBudget() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        Test.startTest();
        AgentGovBudgetManager.BudgetResult result = AgentGovBudgetManager.getRemainingBudget(reg.Id);
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @IsTest
    static void testCreateDailyBudget() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Daily Budget Agent', 'MCP_External', true);

        Test.startTest();
        AgentGov_Budget__c budget = AgentGovBudgetManager.createDailyBudget(reg.Id);
        Test.stopTest();

        System.assertNotEquals(null, budget.Id);
        System.assertEquals(Date.today(), budget.Budget_Date__c);
    }

    @IsTest
    static void testResetDailyBudgets() {
        Test.startTest();
        AgentGovBudgetManager.resetDailyBudgets();
        Test.stopTest();

        // Should have created new budget records
        List<AgentGov_Budget__c> budgets = [SELECT Id FROM AgentGov_Budget__c WHERE Budget_Date__c = :Date.today()];
        System.assert(budgets.size() >= 1, 'Should have at least 1 budget after reset');
    }
}
