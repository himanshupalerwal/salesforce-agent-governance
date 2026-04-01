@IsTest
private class AgentGovCircuitBreakerTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    @IsTest
    static void testAllowRequestClosed() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);

        Test.startTest();
        Boolean allowed = AgentGovCircuitBreaker.allowRequest(reg.Id);
        Test.stopTest();

        System.assertEquals(true, allowed, 'CLOSED state should allow requests');
    }

    @IsTest
    static void testAllowRequestOpenBeforeCooldown() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        reg.Cooldown_Until__c = DateTime.now().addHours(1);
        update reg;
        AgentGovSelector.clearCache();

        Test.startTest();
        Boolean allowed = AgentGovCircuitBreaker.allowRequest(reg.Id);
        Test.stopTest();

        System.assertEquals(false, allowed, 'OPEN state before cooldown should block');
    }

    @IsTest
    static void testAllowRequestOpenAfterCooldown() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        reg.Cooldown_Until__c = DateTime.now().addHours(-1);
        reg.Status__c = AgentGovConstants.STATUS_BLOCKED;
        update reg;
        AgentGovSelector.clearCache();

        Test.startTest();
        Boolean allowed = AgentGovCircuitBreaker.allowRequest(reg.Id);
        Test.stopTest();

        System.assertEquals(true, allowed, 'OPEN state after cooldown should transition to HALF_OPEN and allow');
    }

    @IsTest
    static void testAllowRequestHalfOpen() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_HALF_OPEN;
        update reg;
        AgentGovSelector.clearCache();

        Test.startTest();
        Boolean allowed = AgentGovCircuitBreaker.allowRequest(reg.Id);
        Test.stopTest();

        System.assertEquals(true, allowed, 'HALF_OPEN should allow test request');
    }

    @IsTest
    static void testRecordSuccessHalfOpen() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_HALF_OPEN;
        reg.Failure_Count__c = 5;
        update reg;
        AgentGovSelector.clearCache();

        Test.startTest();
        AgentGovCircuitBreaker.recordSuccess(reg.Id);
        Test.stopTest();

        AgentGov_Registration__c updated = [SELECT Circuit_Breaker_State__c, Failure_Count__c FROM AgentGov_Registration__c WHERE Id = :reg.Id];
        System.assertEquals(AgentGovConstants.CB_CLOSED, updated.Circuit_Breaker_State__c, 'Should close after HALF_OPEN success');
        System.assertEquals(0, updated.Failure_Count__c, 'Should reset failure count');
    }

    @IsTest
    static void testRecordFailureTrips() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Circuit_Breaker_Failure_Threshold__c = 3;
        update settings;
        AgentGovSelector.clearCache();

        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);
        reg.Failure_Count__c = 2;
        update reg;
        AgentGovSelector.clearCache();

        Test.startTest();
        AgentGovCircuitBreaker.recordFailure(reg.Id);
        Test.stopTest();

        AgentGov_Registration__c updated = [SELECT Circuit_Breaker_State__c, Status__c FROM AgentGov_Registration__c WHERE Id = :reg.Id];
        System.assertEquals(AgentGovConstants.CB_OPEN, updated.Circuit_Breaker_State__c, 'Should trip to OPEN');
        System.assertEquals(AgentGovConstants.STATUS_BLOCKED, updated.Status__c, 'Should block agent');
    }

    @IsTest
    static void testRecordFailureHalfOpenRetry() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_HALF_OPEN;
        update reg;
        AgentGovSelector.clearCache();

        Test.startTest();
        AgentGovCircuitBreaker.recordFailure(reg.Id);
        Test.stopTest();

        AgentGov_Registration__c updated = [SELECT Circuit_Breaker_State__c FROM AgentGov_Registration__c WHERE Id = :reg.Id];
        System.assertEquals(AgentGovConstants.CB_OPEN, updated.Circuit_Breaker_State__c, 'HALF_OPEN failure goes back to OPEN');
    }

    @IsTest
    static void testGetState() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);

        Test.startTest();
        String state = AgentGovCircuitBreaker.getState(reg.Id);
        Test.stopTest();

        System.assertEquals(AgentGovConstants.CB_CLOSED, state);
    }

    @IsTest
    static void testResetBreaker() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        reg.Failure_Count__c = 10;
        reg.Status__c = AgentGovConstants.STATUS_BLOCKED;
        update reg;
        AgentGovSelector.clearCache();

        Test.startTest();
        AgentGovCircuitBreaker.resetBreaker(reg.Id);
        Test.stopTest();

        AgentGov_Registration__c updated = [SELECT Circuit_Breaker_State__c, Failure_Count__c, Status__c FROM AgentGov_Registration__c WHERE Id = :reg.Id];
        System.assertEquals(AgentGovConstants.CB_CLOSED, updated.Circuit_Breaker_State__c);
        System.assertEquals(0, updated.Failure_Count__c);
        System.assertEquals(AgentGovConstants.STATUS_ACTIVE, updated.Status__c);
    }

    @IsTest
    static void testAllowRequestAgentNotFound() {
        Test.startTest();
        try {
            AgentGovCircuitBreaker.allowRequest('a00000000000001AAA');
            System.assert(false, 'Should throw');
        } catch (AgentGovException e) {
            System.assertEquals(AgentGovException.ErrorCode.AGENT_NOT_FOUND, e.getErrorCode());
        }
        Test.stopTest();
    }

    @IsTest
    static void testRecordFailureBelowThreshold() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('CB Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovCircuitBreaker.recordFailure(reg.Id);
        Test.stopTest();

        AgentGov_Registration__c updated = [SELECT Circuit_Breaker_State__c, Failure_Count__c FROM AgentGov_Registration__c WHERE Id = :reg.Id];
        System.assertEquals(AgentGovConstants.CB_CLOSED, updated.Circuit_Breaker_State__c, 'Should stay CLOSED');
        System.assertEquals(1, updated.Failure_Count__c, 'Should increment failure count');
    }
}
