/**
 * @description Tests for the Get Agent Status invocable.
 */
@IsTest
private class AgentGovGetStatusTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    private static AgentGovGetStatus.Request request(Id registrationId) {
        AgentGovGetStatus.Request req = new AgentGovGetStatus.Request();
        req.registrationId = registrationId;
        return req;
    }

    @IsTest
    static void reportsHealthAndUnknownAgents() {
        AgentGov_Registration__c healthy = AgentGovTestDataFactory.createRegistration(
            'Status Agent',
            'Agentforce',
            true
        );
        AgentGov_Registration__c tripped = AgentGovTestDataFactory.createRegistration(
            'Tripped Agent',
            'Agentforce',
            false
        );
        tripped.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        tripped.Status__c = AgentGovConstants.STATUS_BLOCKED;
        tripped.Failure_Count__c = 5;
        insert tripped;
        Id unknownId = AgentGov_Registration__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';

        List<AgentGovGetStatus.Result> results = AgentGovGetStatus.getStatus(
            new List<AgentGovGetStatus.Request>{ request(healthy.Id), request(tripped.Id), request(unknownId) }
        );

        Assert.areEqual('Status Agent', results[0].agentName);
        Assert.areEqual(AgentGovConstants.STATUS_ACTIVE, results[0].agentStatus);
        Assert.areEqual(AgentGovConstants.CB_CLOSED, results[0].circuitBreakerState);
        Assert.isTrue(results[0].isHealthy);
        Assert.isFalse(results[1].isHealthy);
        Assert.areEqual(5, results[1].failureCount);
        Assert.isFalse(results[2].isHealthy);
        Assert.areEqual(AgentGovConstants.ERR_AGENT_NOT_FOUND, results[2].errorMessage);
    }
}
