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
        return request(registrationId, AgentGovConstants.ACTION_SUCCESS, details);
    }

    private static AgentGovLogAction.Request request(Id registrationId, String status, String details) {
        AgentGovLogAction.Request req = new AgentGovLogAction.Request();
        req.registrationId = registrationId;
        req.actionType = AgentGovConstants.ACTION_QUERY;
        req.objectName = 'Account';
        req.recordId = '001000000000001AAA';
        req.status = status;
        req.details = details;
        return req;
    }

    private static void setFailureThreshold(Integer threshold) {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Circuit_Breaker_Failure_Threshold__c = threshold;
        update settings;
        AgentGovSelector.clearCache();
    }

    private static AgentGov_Registration__c breakerOf(Id registrationId) {
        return [
            SELECT Circuit_Breaker_State__c, Status__c, Failure_Count__c
            FROM AgentGov_Registration__c
            WHERE Id = :registrationId
        ];
    }

    private static void logFailures(Id registrationId, Integer count) {
        for (Integer i = 0; i < count; i++) {
            AgentGovLogAction.logAction(
                new List<AgentGovLogAction.Request>{
                    request(registrationId, AgentGovConstants.ACTION_FAILURE, 'attempt ' + i)
                }
            );
        }
    }

    @IsTest
    static void failuresLoggedFromFlowTripTheBreaker() {
        setFailureThreshold(3);
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Flow Agent', 'Flow_Based', true);

        Test.startTest();
        logFailures(reg.Id, 3);
        Test.stopTest();

        AgentGov_Registration__c tripped = breakerOf(reg.Id);
        Assert.areEqual(
            AgentGovConstants.CB_OPEN,
            tripped.Circuit_Breaker_State__c,
            'Three failures logged from Flow trip the breaker as failures reported over REST do'
        );
        Assert.areEqual(AgentGovConstants.STATUS_BLOCKED, tripped.Status__c);
    }

    @IsTest
    static void aBatchCountsOnceAndAFailureOutweighsASuccess() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Flow Agent', 'Flow_Based', true);

        Test.startTest();
        AgentGovLogAction.logAction(
            new List<AgentGovLogAction.Request>{
                request(reg.Id, AgentGovConstants.ACTION_SUCCESS, 'first'),
                request(reg.Id, AgentGovConstants.ACTION_FAILURE, 'second'),
                request(reg.Id, AgentGovConstants.ACTION_SUCCESS, 'third'),
                request(reg.Id, AgentGovConstants.ACTION_DENIED, 'fourth')
            }
        );
        Test.stopTest();

        AgentGov_Registration__c after = breakerOf(reg.Id);
        Assert.areEqual(1, after.Failure_Count__c, 'One batch is one outcome, and a failure in it makes it a failure');
        Assert.areEqual(AgentGovConstants.CB_CLOSED, after.Circuit_Breaker_State__c);
    }

    @IsTest
    static void aSuccessLoggedFromFlowClosesAHalfOpenBreaker() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Flow Agent', 'Flow_Based', true);
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_HALF_OPEN;
        reg.Status__c = AgentGovConstants.STATUS_THROTTLED;
        reg.Failure_Count__c = 2;
        update reg;
        AgentGovSelector.clearCache();

        Test.startTest();
        AgentGovLogAction.logAction(
            new List<AgentGovLogAction.Request>{ request(reg.Id, AgentGovConstants.ACTION_SUCCESS, 'probe') }
        );
        Test.stopTest();

        AgentGov_Registration__c after = breakerOf(reg.Id);
        Assert.areEqual(AgentGovConstants.CB_CLOSED, after.Circuit_Breaker_State__c, 'The probe succeeded');
        Assert.areEqual(AgentGovConstants.STATUS_ACTIVE, after.Status__c);
        Assert.areEqual(0, after.Failure_Count__c);
    }

    @IsTest
    static void outcomesAreNotCountedForADeactivatedAgentOrDuringTheBypass() {
        setFailureThreshold(3);
        AgentGov_Registration__c retired = AgentGovTestDataFactory.createRegistration('Retired', 'Flow_Based', true);
        retired.Status__c = AgentGovConstants.STATUS_INACTIVE;
        update retired;
        AgentGov_Registration__c bypassed = AgentGovTestDataFactory.createRegistration('Bypassed', 'Flow_Based', true);
        AgentGovSelector.clearCache();

        Test.startTest();
        logFailures(retired.Id, 3);
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();
        logFailures(bypassed.Id, 3);
        Test.getEventBus().deliver();
        Test.stopTest();

        AgentGov_Registration__c stillRetired = breakerOf(retired.Id);
        Assert.areEqual(
            AgentGovConstants.STATUS_INACTIVE,
            stillRetired.Status__c,
            'A tripped breaker must not revive it'
        );
        Assert.areEqual(AgentGovConstants.CB_CLOSED, stillRetired.Circuit_Breaker_State__c);
        AgentGov_Registration__c untouched = breakerOf(bypassed.Id);
        Assert.areEqual(
            AgentGovConstants.CB_CLOSED,
            untouched.Circuit_Breaker_State__c,
            'No outcome during the bypass'
        );
        Assert.isTrue(untouched.Failure_Count__c == null || untouched.Failure_Count__c == 0);
        Assert.areEqual(
            6,
            [
                SELECT COUNT()
                FROM AgentGov_Action_Log__c
                WHERE
                    Agent_Registration__c IN (:retired.Id, :bypassed.Id)
                    AND Status__c = :AgentGovConstants.ACTION_FAILURE
            ],
            'The rows are still written; only the breaker is left alone'
        );
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
