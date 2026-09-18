/**
 * @description Tests for the Check Agent Budget invocable.
 */
@IsTest
private class AgentGovCheckBudgetTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'Budget Check Agent',
            'Agentforce',
            true
        );
        AgentGovTestDataFactory.createBudget(reg.Id, true);
    }

    private static AgentGovCheckBudget.Request request(Id registrationId) {
        AgentGovCheckBudget.Request req = new AgentGovCheckBudget.Request();
        req.registrationId = registrationId;
        return req;
    }

    @IsTest
    static void returnsBudgetForKnownAgentsAndErrorsForOthers() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        Id unknownId = AgentGov_Registration__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';

        Test.startTest();
        List<AgentGovCheckBudget.Result> results = AgentGovCheckBudget.checkBudget(
            new List<AgentGovCheckBudget.Request>{ request(reg.Id), request(null), request(unknownId) }
        );
        Test.stopTest();

        Assert.areEqual(3, results.size());
        Assert.isTrue(results[0].hasBudget);
        Assert.areEqual(AgentGovConstants.BUDGET_NORMAL, results[0].budgetStatus);
        Assert.areEqual(10000, results[0].apiCallsRemaining);
        Assert.isFalse(results[1].hasBudget);
        Assert.areEqual(AgentGovConstants.ERR_NULL_AGENT_ID, results[1].errorMessage);
        Assert.isFalse(results[2].hasBudget);
        Assert.areEqual(AgentGovConstants.ERR_AGENT_NOT_FOUND, results[2].errorMessage);
    }
}
