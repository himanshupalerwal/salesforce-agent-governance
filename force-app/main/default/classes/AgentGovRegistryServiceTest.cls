@IsTest
private class AgentGovRegistryServiceTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    @IsTest
    static void testRegisterAgent() {
        Test.startTest();
        AgentGov_Registration__c reg = AgentGovRegistryService.registerAgent(
            'New Agent', 'Agentforce', 'Test description', 'key-001', 'test@test.com'
        );
        Test.stopTest();

        System.assertNotEquals(null, reg.Id, 'Should create a registration');
        System.assertEquals('New Agent', reg.Agent_Name__c);
        System.assertEquals(AgentGovConstants.STATUS_INACTIVE, reg.Status__c, 'New agents should start as Inactive');
    }

    @IsTest
    static void testRegisterAgentInvalidName() {
        Test.startTest();
        try {
            AgentGovRegistryService.registerAgent('', 'Agentforce', null, null, null);
            System.assert(false, 'Should have thrown exception');
        } catch (AgentGovException e) {
            System.assertEquals(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
        }
        Test.stopTest();
    }

    @IsTest
    static void testRegisterAgentInvalidType() {
        Test.startTest();
        try {
            AgentGovRegistryService.registerAgent('Agent', 'InvalidType', null, null, null);
            System.assert(false, 'Should have thrown exception');
        } catch (AgentGovException e) {
            System.assertEquals(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
        }
        Test.stopTest();
    }

    @IsTest
    static void testActivateAgent() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Test', 'Agentforce', true);
        reg.Status__c = AgentGovConstants.STATUS_INACTIVE;
        update reg;
        AgentGovSelector.clearCache();

        Test.startTest();
        AgentGov_Registration__c result = AgentGovRegistryService.activateAgent(reg.Id);
        Test.stopTest();

        System.assertEquals(AgentGovConstants.STATUS_ACTIVE, result.Status__c);
    }

    @IsTest
    static void testActivateAgentNotFound() {
        Test.startTest();
        try {
            // Use a fake but valid-format ID
            AgentGovRegistryService.activateAgent('a00000000000001AAA');
            System.assert(false, 'Should have thrown exception');
        } catch (AgentGovException e) {
            System.assertEquals(AgentGovException.ErrorCode.AGENT_NOT_FOUND, e.getErrorCode());
        }
        Test.stopTest();
    }

    @IsTest
    static void testDeactivateAgent() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Test', 'Agentforce', true);
        AgentGovTestDataFactory.createSession(reg.Id, true);

        Test.startTest();
        AgentGov_Registration__c result = AgentGovRegistryService.deactivateAgent(reg.Id);
        Test.stopTest();

        System.assertEquals(AgentGovConstants.STATUS_INACTIVE, result.Status__c);
        // Verify session was terminated
        AgentGov_Session__c session = [SELECT Status__c FROM AgentGov_Session__c WHERE Agent_Registration__c = :reg.Id LIMIT 1];
        System.assertEquals(AgentGovConstants.SESSION_TERMINATED, session.Status__c);
    }

    @IsTest
    static void testStartSession() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Test', 'Agentforce', true);

        Test.startTest();
        AgentGov_Session__c session = AgentGovRegistryService.startSession(reg.Id);
        Test.stopTest();

        System.assertNotEquals(null, session.Id);
        System.assertEquals(AgentGovConstants.SESSION_ACTIVE, session.Status__c);
    }

    @IsTest
    static void testStartSessionInactiveAgent() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Test', 'Agentforce', true);
        reg.Status__c = AgentGovConstants.STATUS_INACTIVE;
        update reg;
        AgentGovSelector.clearCache();

        Test.startTest();
        try {
            AgentGovRegistryService.startSession(reg.Id);
            System.assert(false, 'Should have thrown exception');
        } catch (AgentGovException e) {
            System.assertEquals(AgentGovException.ErrorCode.AGENT_NOT_ACTIVE, e.getErrorCode());
        }
        Test.stopTest();
    }

    @IsTest
    static void testEndSession() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Test', 'Agentforce', true);
        AgentGov_Session__c session = AgentGovTestDataFactory.createSession(reg.Id, true);

        Test.startTest();
        AgentGov_Session__c result = AgentGovRegistryService.endSession(session.Id);
        Test.stopTest();

        System.assertEquals(AgentGovConstants.SESSION_COMPLETED, result.Status__c);
        System.assertNotEquals(null, result.Session_End__c);
    }

    @IsTest
    static void testGetAgent() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Test', 'Agentforce', true);

        Test.startTest();
        AgentGov_Registration__c result = AgentGovRegistryService.getAgent(reg.Id);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals('Test', result.Agent_Name__c);
    }

    @IsTest
    static void testMaxConcurrentAgents() {
        // Set max to 1
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Max_Concurrent_Agents__c = 1;
        update settings;
        AgentGovSelector.clearCache();

        // First agent is already active from createRegistration
        AgentGovTestDataFactory.createRegistration('Agent 1', 'Agentforce', true);

        // Try to activate a second
        AgentGov_Registration__c reg2 = AgentGovTestDataFactory.createRegistration('Agent 2', 'Custom_Apex', false);
        reg2.Status__c = AgentGovConstants.STATUS_INACTIVE;
        insert reg2;
        AgentGovSelector.clearCache();

        Test.startTest();
        try {
            AgentGovRegistryService.activateAgent(reg2.Id);
            System.assert(false, 'Should have thrown exception for max concurrent');
        } catch (AgentGovException e) {
            System.assertEquals(AgentGovException.ErrorCode.MAX_CONCURRENT_AGENTS, e.getErrorCode());
        }
        Test.stopTest();
    }
}
