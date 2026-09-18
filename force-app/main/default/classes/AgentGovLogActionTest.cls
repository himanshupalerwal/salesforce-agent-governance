/**
 * @description Tests for the Log Agent Action invocable.
 */
@IsTest
private class AgentGovLogActionTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    private static AgentGovLogAction.Request request(Id registrationId, String details) {
        AgentGovLogAction.Request req = new AgentGovLogAction.Request();
        req.registrationId = registrationId;
        req.actionType = AgentGovConstants.ACTION_QUERY;
        req.objectName = 'Account';
        req.recordId = '001000000000001AAA';
        req.status = AgentGovConstants.ACTION_SUCCESS;
        req.details = details;
        return req;
    }

    @IsTest
    static void logsEveryRequestWithOnePublish() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Log Agent', 'Flow_Based', true);

        Test.startTest();
        List<AgentGovLogAction.Result> results = AgentGovLogAction.logAction(
            new List<AgentGovLogAction.Request>{
                request(reg.Id, 'first'),
                request(reg.Id, 'second'),
                request(null, 'no agent')
            }
        );
        Integer dml = Limits.getDmlStatements();
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.isTrue(results[0].success);
        Assert.isTrue(results[1].success);
        Assert.isFalse(results[2].success);
        Assert.areEqual(AgentGovConstants.ERR_NULL_AGENT_ID, results[2].errorMessage);
        Assert.areEqual(1, dml, 'One publish for the whole batch');
        Assert.areEqual(2, [SELECT COUNT() FROM AgentGov_Action_Log__c WHERE Agent_Registration__c = :reg.Id]);
    }
}
