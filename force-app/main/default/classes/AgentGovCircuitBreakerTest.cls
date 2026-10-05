/**
 * @description Tests for AgentGovCircuitBreaker, including the single-probe HALF_OPEN
 *              behaviour and the doubled, capped retry cooldown.
 */
@IsTest
private class AgentGovCircuitBreakerTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    private static AgentGov_Registration__c agentInState(String state, String status, DateTime cooldownUntil) {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', false);
        reg.Circuit_Breaker_State__c = state;
        reg.Status__c = status;
        reg.Cooldown_Until__c = cooldownUntil;
        insert reg;
        return reg;
    }

    private static AgentGov_Registration__c reload(Id registrationId) {
        return [
            SELECT
                Circuit_Breaker_State__c,
                Status__c,
                Failure_Count__c,
                Last_Failure__c,
                Cooldown_Until__c,
                Half_Open_Probe_At__c
            FROM AgentGov_Registration__c
            WHERE Id = :registrationId
        ];
    }

    @IsTest
    static void closedBreakerAllowsRequests() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);
        Assert.isTrue(AgentGovCircuitBreaker.allowRequest(reg.Id));
    }

    @IsTest
    static void openBreakerBlocksUntilCooldown() {
        AgentGov_Registration__c reg = agentInState(
            AgentGovConstants.CB_OPEN,
            AgentGovConstants.STATUS_BLOCKED,
            DateTime.now().addHours(1)
        );
        Assert.isFalse(AgentGovCircuitBreaker.allowRequest(reg.Id));
        Assert.areEqual(AgentGovConstants.CB_OPEN, reload(reg.Id).Circuit_Breaker_State__c);
    }

    @IsTest
    static void openBreakerPastCooldownAdmitsOneProbe() {
        AgentGov_Registration__c reg = agentInState(
            AgentGovConstants.CB_OPEN,
            AgentGovConstants.STATUS_BLOCKED,
            DateTime.now().addHours(-1)
        );

        Test.startTest();
        Boolean first = AgentGovCircuitBreaker.allowRequest(reg.Id);
        Boolean second = AgentGovCircuitBreaker.allowRequest(reg.Id);
        Test.stopTest();

        Assert.isTrue(first, 'The first request after cooldown is the probe');
        Assert.isFalse(second, 'No second request is admitted while the probe is outstanding');
        AgentGov_Registration__c updated = reload(reg.Id);
        Assert.areEqual(AgentGovConstants.CB_HALF_OPEN, updated.Circuit_Breaker_State__c);
        Assert.areEqual(AgentGovConstants.STATUS_THROTTLED, updated.Status__c);
        Assert.isNotNull(updated.Half_Open_Probe_At__c);
    }

    @IsTest
    static void halfOpenAdmitsExactlyOneProbe() {
        AgentGov_Registration__c reg = agentInState(
            AgentGovConstants.CB_HALF_OPEN,
            AgentGovConstants.STATUS_THROTTLED,
            null
        );

        Boolean first = AgentGovCircuitBreaker.allowRequest(reg.Id);
        Boolean second = AgentGovCircuitBreaker.allowRequest(reg.Id);

        Assert.isTrue(first);
        Assert.isFalse(second);
    }

    @IsTest
    static void abandonedProbeIsReplacedAfterCooldownWindow() {
        AgentGov_Registration__c reg = agentInState(
            AgentGovConstants.CB_HALF_OPEN,
            AgentGovConstants.STATUS_THROTTLED,
            null
        );
        reg.Half_Open_Probe_At__c = DateTime.now().addHours(-2);
        update reg;
        AgentGovSelector.clearCache();

        Assert.isTrue(
            AgentGovCircuitBreaker.allowRequest(reg.Id),
            'A probe older than the cooldown window is treated as abandoned'
        );
    }

    @IsTest
    static void successfulProbeClosesBreaker() {
        AgentGov_Registration__c reg = agentInState(
            AgentGovConstants.CB_HALF_OPEN,
            AgentGovConstants.STATUS_THROTTLED,
            null
        );
        reg.Failure_Count__c = 5;
        reg.Half_Open_Probe_At__c = DateTime.now();
        update reg;
        AgentGovSelector.clearCache();

        Test.startTest();
        AgentGovCircuitBreaker.recordSuccess(reg.Id);
        Test.stopTest();

        AgentGov_Registration__c updated = reload(reg.Id);
        Assert.areEqual(AgentGovConstants.CB_CLOSED, updated.Circuit_Breaker_State__c);
        Assert.areEqual(0, updated.Failure_Count__c);
        Assert.areEqual(AgentGovConstants.STATUS_ACTIVE, updated.Status__c);
        Assert.isNull(updated.Half_Open_Probe_At__c);
    }

    @IsTest
    static void failuresTripBreakerAtThreshold() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Circuit_Breaker_Failure_Threshold__c = 3;
        update settings;
        AgentGovSelector.clearCache();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovCircuitBreaker.recordFailure(reg.Id);
        AgentGovCircuitBreaker.recordFailure(reg.Id);
        Assert.areEqual(
            AgentGovConstants.CB_CLOSED,
            reload(reg.Id).Circuit_Breaker_State__c,
            'Below the threshold the breaker stays closed'
        );
        AgentGovCircuitBreaker.recordFailure(reg.Id);
        Test.stopTest();

        AgentGov_Registration__c updated = reload(reg.Id);
        Assert.areEqual(AgentGovConstants.CB_OPEN, updated.Circuit_Breaker_State__c);
        Assert.areEqual(AgentGovConstants.STATUS_BLOCKED, updated.Status__c);
        Assert.areEqual(3, updated.Failure_Count__c);
        Assert.isTrue(updated.Cooldown_Until__c > DateTime.now(), 'A cooldown is scheduled');
    }

    @IsTest
    static void aSuccessClearsTheFailureTallyOnAClosedBreaker() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Circuit_Breaker_Failure_Threshold__c = 3;
        update settings;
        AgentGovSelector.clearCache();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovCircuitBreaker.recordFailure(reg.Id);
        AgentGovCircuitBreaker.recordFailure(reg.Id);
        Assert.areEqual(2, reload(reg.Id).Failure_Count__c, 'Two failures are tallied');

        AgentGovCircuitBreaker.recordSuccess(reg.Id);
        Test.stopTest();

        // The threshold counts CONSECUTIVE failures. Without this reset the tally would be a
        // lifetime total and an agent would eventually trip on failures months apart.
        AgentGov_Registration__c afterSuccess = reload(reg.Id);
        Assert.areEqual(0, afterSuccess.Failure_Count__c, 'A success clears the consecutive-failure tally');
        Assert.isNull(afterSuccess.Last_Failure__c, 'The last-failure stamp is cleared with the tally');
        Assert.areEqual(AgentGovConstants.CB_CLOSED, afterSuccess.Circuit_Breaker_State__c, 'The breaker stays closed');
    }

    @IsTest
    static void interleavedFailuresNeverTripAHealthyAgent() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Circuit_Breaker_Failure_Threshold__c = 3;
        update settings;
        AgentGovSelector.clearCache();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);

        Test.startTest();
        for (Integer i = 0; i < 5; i++) {
            AgentGovCircuitBreaker.recordFailure(reg.Id);
            AgentGovCircuitBreaker.recordSuccess(reg.Id);
        }
        Test.stopTest();

        AgentGov_Registration__c updated = reload(reg.Id);
        Assert.areEqual(
            AgentGovConstants.CB_CLOSED,
            updated.Circuit_Breaker_State__c,
            'Five isolated failures separated by successes never reach the threshold'
        );
        Assert.areEqual(0, updated.Failure_Count__c);
    }

    @IsTest
    static void failedProbeReopensWithDoubledCooldown() {
        AgentGov_Registration__c reg = agentInState(
            AgentGovConstants.CB_HALF_OPEN,
            AgentGovConstants.STATUS_THROTTLED,
            null
        );
        reg.Failure_Count__c = 3;
        update reg;
        AgentGovSelector.clearCache();

        Test.startTest();
        AgentGovCircuitBreaker.recordFailure(reg.Id);
        Test.stopTest();

        AgentGov_Registration__c updated = reload(reg.Id);
        Assert.areEqual(AgentGovConstants.CB_OPEN, updated.Circuit_Breaker_State__c);
        Long minutes = (updated.Cooldown_Until__c.getTime() - DateTime.now().getTime()) / 60000;
        Assert.isTrue(minutes >= 55 && minutes <= 60, 'Cooldown is doubled from the 30 minute default, got ' + minutes);
        Assert.areEqual(4, updated.Failure_Count__c, 'The failed probe extends the run of consecutive failures');
        Assert.isNotNull(updated.Last_Failure__c, 'The failed probe is the latest failure');
    }

    @IsTest
    static void outcomesRecordedWhileOpenChangeNothing() {
        AgentGov_Registration__c reg = agentInState(
            AgentGovConstants.CB_OPEN,
            AgentGovConstants.STATUS_BLOCKED,
            DateTime.now().addMinutes(20)
        );
        reg.Failure_Count__c = 3;
        update reg;
        AgentGovSelector.clearCache();
        AgentGov_Registration__c before = reload(reg.Id);

        Test.startTest();
        AgentGovCircuitBreaker.recordFailure(reg.Id);
        AgentGovCircuitBreaker.recordSuccess(reg.Id);
        Integer writes = Limits.getDmlStatements();
        Test.stopTest();

        AgentGov_Registration__c after = reload(reg.Id);
        Assert.areEqual(
            AgentGovConstants.CB_OPEN,
            after.Circuit_Breaker_State__c,
            'Only the probe or a reset ends OPEN'
        );
        Assert.areEqual(before.Cooldown_Until__c, after.Cooldown_Until__c, 'A failure does not restart the cooldown');
        Assert.areEqual(3, after.Failure_Count__c, 'Neither outcome changes the count');
        Assert.areEqual(0, writes, 'Nothing is written and no second alert is published');
    }

    @IsTest
    static void cooldownIsCappedAtOneDay() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Circuit_Breaker_Cooldown_Minutes__c = 1000;
        update settings;
        AgentGovSelector.clearCache();
        AgentGov_Registration__c reg = agentInState(
            AgentGovConstants.CB_HALF_OPEN,
            AgentGovConstants.STATUS_THROTTLED,
            null
        );

        AgentGovCircuitBreaker.recordFailure(reg.Id);

        Long minutes = (reload(reg.Id).Cooldown_Until__c.getTime() - DateTime.now().getTime()) / 60000;
        Assert.isTrue(
            minutes <= AgentGovConstants.CB_MAX_COOLDOWN_MINUTES,
            'Doubling never exceeds the cap, got ' + minutes
        );
    }

    @IsTest
    static void tripAtThresholdOfOneBlocksImmediately() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Circuit_Breaker_Failure_Threshold__c = 1;
        update settings;
        AgentGovSelector.clearCache();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovCircuitBreaker.recordFailure(reg.Id);
        Integer publishes = Limits.getDmlStatements();
        Test.stopTest();

        AgentGov_Registration__c updated = reload(reg.Id);
        Assert.areEqual(AgentGovConstants.CB_OPEN, updated.Circuit_Breaker_State__c);
        Assert.areEqual(AgentGovConstants.STATUS_BLOCKED, updated.Status__c);
        Assert.areEqual(2, publishes, 'One registration update and one alert publish');
    }

    @IsTest
    static void getStateAndResetBreaker() {
        AgentGov_Registration__c reg = agentInState(
            AgentGovConstants.CB_OPEN,
            AgentGovConstants.STATUS_BLOCKED,
            DateTime.now().addHours(1)
        );
        reg.Failure_Count__c = 10;
        update reg;
        AgentGovSelector.clearCache();

        Assert.areEqual(AgentGovConstants.CB_OPEN, AgentGovCircuitBreaker.getState(reg.Id));
        AgentGovCircuitBreaker.resetBreaker(reg.Id);

        AgentGov_Registration__c updated = reload(reg.Id);
        Assert.areEqual(AgentGovConstants.CB_CLOSED, updated.Circuit_Breaker_State__c);
        Assert.areEqual(0, updated.Failure_Count__c);
        Assert.areEqual(AgentGovConstants.STATUS_ACTIVE, updated.Status__c);
    }

    @IsTest
    static void unknownAgentIsRejected() {
        Id unknownId = AgentGov_Registration__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';
        try {
            AgentGovCircuitBreaker.allowRequest(unknownId);
            Assert.fail('An unknown agent must be rejected');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.AGENT_NOT_FOUND, e.getErrorCode());
        }
        Assert.isFalse(AgentGovCircuitBreaker.allowRequests(new Set<Id>{ unknownId }).containsKey(unknownId));
    }

    @IsTest
    static void transitionToHalfOpenHandlesOnlyOpenBreakers() {
        AgentGov_Registration__c open = agentInState(
            AgentGovConstants.CB_OPEN,
            AgentGovConstants.STATUS_BLOCKED,
            DateTime.now().addHours(-1)
        );
        AgentGov_Registration__c closed = AgentGovTestDataFactory.createRegistration(
            'Closed Agent',
            'Agentforce',
            true
        );

        AgentGovCircuitBreaker.transitionToHalfOpen(new List<AgentGov_Registration__c>{ open, closed });

        Assert.areEqual(AgentGovConstants.CB_HALF_OPEN, reload(open.Id).Circuit_Breaker_State__c);
        Assert.areEqual(AgentGovConstants.CB_CLOSED, reload(closed.Id).Circuit_Breaker_State__c);
    }

    @IsTest
    static void theHealthCheckLeavesABreakerThatReopenedSinceItsReadAlone() {
        AgentGov_Registration__c reg = agentInState(
            AgentGovConstants.CB_OPEN,
            AgentGovConstants.STATUS_BLOCKED,
            DateTime.now().addMinutes(-5)
        );
        List<AgentGov_Registration__c> readByTheJob = AgentGovSelector.getOpenAgentsPastCooldown();
        Assert.areEqual(1, readByTheJob.size(), 'The job sees the breaker as due');
        // Between the job's unlocked read and its lock, a probe ran, failed, and re-opened the
        // breaker with a new cooldown.
        update new AgentGov_Registration__c(Id = reg.Id, Cooldown_Until__c = DateTime.now().addMinutes(60));
        DateTime newCooldown = reload(reg.Id).Cooldown_Until__c;

        Test.startTest();
        AgentGovCircuitBreaker.transitionToHalfOpen(readByTheJob);
        Test.stopTest();

        AgentGov_Registration__c after = reload(reg.Id);
        Assert.areEqual(AgentGovConstants.CB_OPEN, after.Circuit_Breaker_State__c, 'The new cooldown is served');
        Assert.areEqual(newCooldown, after.Cooldown_Until__c, 'The new cooldown is kept');
        Assert.areEqual(AgentGovConstants.STATUS_BLOCKED, after.Status__c, 'The agent stays Blocked');
    }

    @IsTest
    static void aSuccessOnAHealthyBreakerTakesNoLockAndWritesNothing() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);
        // The transaction already holds the agent, as every caller does by the time it records
        // an outcome.
        AgentGovSelector.getRegistrationById(reg.Id);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        AgentGovCircuitBreaker.recordSuccess(reg.Id);
        Integer queries = Limits.getQueries() - queriesBefore;
        Integer writes = Limits.getDmlStatements();
        Test.stopTest();

        // No query means no FOR UPDATE: a healthy agent's success never locks the registration,
        // so it cannot take that lock after the session lock its charge took.
        Assert.areEqual(0, queries, 'No locking read');
        Assert.areEqual(0, writes, 'Nothing to write');
        AgentGov_Registration__c after = reload(reg.Id);
        Assert.areEqual(AgentGovConstants.CB_CLOSED, after.Circuit_Breaker_State__c);
        Assert.areEqual(0, after.Failure_Count__c);
    }

    @IsTest
    static void aSuccessAfterAFailureStillTakesTheLockAndClearsIt() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovCircuitBreaker.recordFailure(reg.Id);
        Integer queriesBefore = Limits.getQueries();
        AgentGovCircuitBreaker.recordSuccess(reg.Id);
        Integer queries = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(1, queries, 'The success that has a failure to clear reads the row under a lock');
        Assert.areEqual(0, reload(reg.Id).Failure_Count__c, 'The failure is cleared');
    }
}
