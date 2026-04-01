@IsTest
private class AgentGovLogActionTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    @IsTest
    static void testLogActionInvocable() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Log Agent', 'Flow_Based', true);

        AgentGovLogAction.Request req = new AgentGovLogAction.Request();
        req.registrationId = reg.Id;
        req.actionType = 'Query';
        req.objectName = 'Account';
        req.recordId = '001000000000001';
        req.status = 'Success';
        req.details = 'Test log';

        Test.startTest();
        List<AgentGovLogAction.Result> results = AgentGovLogAction.logAction(
            new List<AgentGovLogAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].success);
    }
}
