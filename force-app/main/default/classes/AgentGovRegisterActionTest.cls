@IsTest
private class AgentGovRegisterActionTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Action Agent', 'Flow_Based', true);
        AgentGovTestDataFactory.createBudget(reg.Id, true);
    }

    @IsTest
    static void testRegisterActionSuccess() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        AgentGovRegisterAction.Request req = new AgentGovRegisterAction.Request();
        req.registrationId = reg.Id;
        req.actionType = 'Query';
        req.objectName = 'Account';
        req.recordId = '001000000000001';

        Test.startTest();
        List<AgentGovRegisterAction.Result> results = AgentGovRegisterAction.registerAction(
            new List<AgentGovRegisterAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].authorized);
    }

    @IsTest
    static void testRegisterActionFrameworkDisabled() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();

        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        AgentGovRegisterAction.Request req = new AgentGovRegisterAction.Request();
        req.registrationId = reg.Id;
        req.actionType = 'Delete';
        req.objectName = 'Account';

        Test.startTest();
        List<AgentGovRegisterAction.Result> results = AgentGovRegisterAction.registerAction(
            new List<AgentGovRegisterAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(true, results[0].authorized, 'Should bypass when framework disabled');
    }

    @IsTest
    static void testRegisterActionCircuitBreakerOpen() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        reg.Circuit_Breaker_State__c = 'OPEN';
        reg.Cooldown_Until__c = DateTime.now().addHours(1);
        update reg;
        AgentGovSelector.clearCache();

        AgentGovRegisterAction.Request req = new AgentGovRegisterAction.Request();
        req.registrationId = reg.Id;
        req.actionType = 'Query';
        req.objectName = 'Account';

        Test.startTest();
        List<AgentGovRegisterAction.Result> results = AgentGovRegisterAction.registerAction(
            new List<AgentGovRegisterAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(false, results[0].authorized);
        System.assert(results[0].denialReason.contains('Circuit breaker'));
    }
}
