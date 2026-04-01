@IsTest
private class AgentGovHealthCheckTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    @IsTest
    static void testExecuteTransitionsOpenToHalfOpen() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('HC Agent', 'Agentforce', true);
        reg.Circuit_Breaker_State__c = 'OPEN';
        reg.Status__c = 'Blocked';
        reg.Cooldown_Until__c = DateTime.now().addHours(-1);
        update reg;

        Test.startTest();
        AgentGovHealthCheck job = new AgentGovHealthCheck();
        job.execute(null);
        Test.stopTest();

        AgentGov_Registration__c updated = [SELECT Circuit_Breaker_State__c, Status__c FROM AgentGov_Registration__c WHERE Id = :reg.Id];
        System.assertEquals('HALF_OPEN', updated.Circuit_Breaker_State__c, 'Should transition to HALF_OPEN');
        System.assertEquals('Throttled', updated.Status__c, 'Should transition to Throttled');
    }

    @IsTest
    static void testExecuteClosesOrphanedSessions() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('HC Agent', 'Agentforce', true);
        AgentGov_Session__c session = new AgentGov_Session__c(
            Agent_Registration__c = reg.Id,
            Session_Start__c = DateTime.now().addDays(-2),
            Status__c = 'Active',
            API_Calls_Used__c = 0,
            SOQL_Queries_Used__c = 0,
            DML_Statements_Used__c = 0,
            Actions_Count__c = 0
        );
        insert session;

        Test.startTest();
        AgentGovHealthCheck job = new AgentGovHealthCheck();
        job.execute(null);
        Test.stopTest();

        AgentGov_Session__c updated = [SELECT Status__c FROM AgentGov_Session__c WHERE Id = :session.Id];
        System.assertEquals('Terminated', updated.Status__c, 'Orphaned session should be terminated');
    }
}
