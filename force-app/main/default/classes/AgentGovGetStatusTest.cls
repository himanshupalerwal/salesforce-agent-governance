@IsTest
private class AgentGovGetStatusTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    @IsTest
    static void testGetStatusInvocable() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Status Agent', 'Agentforce', true);

        AgentGovGetStatus.Request req = new AgentGovGetStatus.Request();
        req.registrationId = reg.Id;

        Test.startTest();
        List<AgentGovGetStatus.Result> results = AgentGovGetStatus.getStatus(
            new List<AgentGovGetStatus.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('Status Agent', results[0].agentName);
        System.assertEquals('Active', results[0].agentStatus);
        System.assertEquals('CLOSED', results[0].circuitBreakerState);
        System.assertEquals(true, results[0].isHealthy);
    }

    @IsTest
    static void testGetStatusNotFound() {
        AgentGovGetStatus.Request req = new AgentGovGetStatus.Request();
        req.registrationId = 'a00000000000001AAA';

        Test.startTest();
        List<AgentGovGetStatus.Result> results = AgentGovGetStatus.getStatus(
            new List<AgentGovGetStatus.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(false, results[0].isHealthy);
        System.assertNotEquals(null, results[0].errorMessage);
    }
}
