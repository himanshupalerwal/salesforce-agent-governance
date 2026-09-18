/**
 * @description Tests for the scheduled health check.
 */
@IsTest
private class AgentGovHealthCheckTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    @IsTest
    static void openBreakersPastCooldownBecomeHalfOpen() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('HC Agent', 'Agentforce', false);
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        reg.Status__c = AgentGovConstants.STATUS_BLOCKED;
        reg.Cooldown_Until__c = DateTime.now().addHours(-1);
        insert reg;

        Test.startTest();
        new AgentGovHealthCheck().execute(null);
        Test.stopTest();

        AgentGov_Registration__c updated = [
            SELECT Circuit_Breaker_State__c, Status__c
            FROM AgentGov_Registration__c
            WHERE Id = :reg.Id
        ];
        Assert.areEqual(AgentGovConstants.CB_HALF_OPEN, updated.Circuit_Breaker_State__c);
        Assert.areEqual(AgentGovConstants.STATUS_THROTTLED, updated.Status__c);
    }

    @IsTest
    static void orphanedSessionsAreTerminated() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('HC Agent', 'Agentforce', true);
        AgentGov_Session__c stale = AgentGovTestDataFactory.createSession(reg.Id, false);
        stale.Session_Start__c = DateTime.now().addDays(-2);
        insert stale;
        AgentGov_Session__c fresh = AgentGovTestDataFactory.createSession(reg.Id, true);

        Test.startTest();
        new AgentGovHealthCheck().execute(null);
        Test.stopTest();

        Assert.areEqual(
            AgentGovConstants.SESSION_TERMINATED,
            [SELECT Status__c FROM AgentGov_Session__c WHERE Id = :stale.Id].Status__c
        );
        Assert.areEqual(
            AgentGovConstants.SESSION_ACTIVE,
            [SELECT Status__c FROM AgentGov_Session__c WHERE Id = :fresh.Id].Status__c
        );
    }

    @IsTest
    static void jobCanBeScheduled() {
        Test.startTest();
        String jobId = System.schedule('AgentGov Health Check Test', '0 0 * * * ?', new AgentGovHealthCheck());
        Test.stopTest();

        Assert.isNotNull(jobId);
    }
}
