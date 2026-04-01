@IsTest
private class AgentGovCheckBudgetTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Budget Check Agent', 'Agentforce', true);
        AgentGovTestDataFactory.createBudget(reg.Id, true);
    }

    @IsTest
    static void testCheckBudgetInvocable() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        AgentGovCheckBudget.Request req = new AgentGovCheckBudget.Request();
        req.registrationId = reg.Id;

        Test.startTest();
        List<AgentGovCheckBudget.Result> results = AgentGovCheckBudget.checkBudget(
            new List<AgentGovCheckBudget.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].hasBudget);
        System.assertEquals('Normal', results[0].budgetStatus);
    }

    @IsTest
    static void testCheckBudgetInvalidId() {
        AgentGovCheckBudget.Request req = new AgentGovCheckBudget.Request();
        req.registrationId = null;

        Test.startTest();
        List<AgentGovCheckBudget.Result> results = AgentGovCheckBudget.checkBudget(
            new List<AgentGovCheckBudget.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(false, results[0].hasBudget);
        System.assertNotEquals(null, results[0].errorMessage);
    }
}
