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
    static void idleSessionsCloseAtTheirLastActivityAndLiveOnesStayOpen() {
        AgentGov_Registration__c idleAgent = AgentGovTestDataFactory.createRegistration('Idle', 'Agentforce', true);
        AgentGov_Registration__c busyAgent = AgentGovTestDataFactory.createRegistration('Busy', 'Agentforce', true);
        DateTime lastWork = DateTime.now().addHours(-2);
        AgentGov_Session__c idle = AgentGovTestDataFactory.createSession(idleAgent.Id, false);
        idle.Session_Start__c = lastWork.addMinutes(-10);
        idle.Last_Activity__c = lastWork;
        insert idle;
        AgentGov_Session__c live = AgentGovTestDataFactory.createSession(busyAgent.Id, true);

        Test.startTest();
        new AgentGovHealthCheck().execute(null);
        Test.stopTest();

        AgentGov_Session__c closed = [
            SELECT Status__c, End_Reason__c, Session_End__c, Active_Session_Key__c
            FROM AgentGov_Session__c
            WHERE Id = :idle.Id
        ];
        Assert.areEqual(AgentGovConstants.SESSION_COMPLETED, closed.Status__c);
        Assert.areEqual(AgentGovConstants.SESSION_END_IDLE, closed.End_Reason__c);
        Assert.areEqual(
            lastWork,
            closed.Session_End__c,
            'The run ended when the agent last worked, not when the job ran'
        );
        Assert.isNull(closed.Active_Session_Key__c, 'An ended session releases the one-active-session key');
        Assert.areEqual(
            AgentGovConstants.SESSION_ACTIVE,
            [SELECT Status__c FROM AgentGov_Session__c WHERE Id = :live.Id].Status__c,
            'A session used within the idle window stays open'
        );
    }

    @IsTest
    static void sessionsPastTheMaximumDurationAreClosed() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Marathon', 'Agentforce', true);
        AgentGov_Session__c marathon = AgentGovTestDataFactory.createSession(reg.Id, false);
        marathon.Session_Start__c = DateTime.now().addHours(-(AgentGovConstants.MAX_SESSION_HOURS + 1));
        marathon.Last_Activity__c = DateTime.now();
        insert marathon;

        Test.startTest();
        new AgentGovHealthCheck().execute(null);
        Test.stopTest();

        AgentGov_Session__c closed = [SELECT Status__c, End_Reason__c FROM AgentGov_Session__c WHERE Id = :marathon.Id];
        Assert.areEqual(AgentGovConstants.SESSION_COMPLETED, closed.Status__c);
        Assert.areEqual(AgentGovConstants.SESSION_END_MAX_DURATION, closed.End_Reason__c);
    }

    @IsTest
    static void jobIsScheduledHourly() {
        Test.startTest();
        Id jobId = System.schedule('AgentGov Health Check Test', '0 0 * * * ?', new AgentGovHealthCheck());
        Test.stopTest();

        Assert.areEqual('0 0 * * * ?', [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId].CronExpression);
    }
}
