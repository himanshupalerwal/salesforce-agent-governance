@IsTest
private class AgentGovContextTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    @IsTest
    static void testStartAndStopTracking() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Context Test Agent', AgentGovConstants.AGENT_TYPE_CUSTOM_APEX, true);
        reg.Status__c = AgentGovConstants.STATUS_ACTIVE;
        update reg;

        Test.startTest();
        AgentGovContext ctx = AgentGovContext.startTracking(reg.Id);
        System.assertNotEquals(null, ctx, 'Context should be returned');
        System.assertNotEquals(null, AgentGovContext.getCurrentContext(), 'Current context should be set');
        System.assertEquals(reg.Id, AgentGovContext.getCurrentContext().getRegistrationId(), 'Registration ID should match');

        // Perform some SOQL to generate measurable delta
        List<AgentGov_Registration__c> regs = [SELECT Id FROM AgentGov_Registration__c LIMIT 5];

        AgentGovBudgetManager.BudgetResult result = AgentGovContext.stopTracking();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should be returned');
        System.assertEquals(null, AgentGovContext.getCurrentContext(), 'Context should be cleared after stop');
    }

    @IsTest
    static void testStopTrackingWithoutStart() {
        AgentGovContext.currentContext = null;
        try {
            AgentGovContext.stopTracking();
            System.assert(false, 'Should have thrown exception');
        } catch (AgentGovException e) {
            System.assert(e.getMessage().contains('No active'), 'Should indicate no active context');
        }
    }

    @IsTest
    static void testExecuteGoverned() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Governed Test Agent', AgentGovConstants.AGENT_TYPE_CUSTOM_APEX, true);
        reg.Status__c = AgentGovConstants.STATUS_ACTIVE;
        update reg;

        Test.startTest();
        AgentGovBudgetManager.BudgetResult result = AgentGovContext.executeGoverned(reg.Id, new TestAction());
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should be returned');
        System.assertEquals(null, AgentGovContext.getCurrentContext(), 'Context should be cleared');
    }

    @IsTest
    static void testStartTrackingNullId() {
        try {
            AgentGovContext.startTracking(null);
            System.assert(false, 'Should have thrown exception');
        } catch (AgentGovException e) {
            System.assert(e.getMessage().contains('null'), 'Should indicate null ID');
        }
    }

    @IsTest
    static void testStartTrackingWithSession() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Session Context Agent', AgentGovConstants.AGENT_TYPE_CUSTOM_APEX, true);
        reg.Status__c = AgentGovConstants.STATUS_ACTIVE;
        update reg;

        AgentGov_Session__c session = new AgentGov_Session__c(
            Agent_Registration__c = reg.Id,
            Session_Start__c = DateTime.now(),
            Status__c = AgentGovConstants.SESSION_ACTIVE,
            API_Calls_Used__c = 0, SOQL_Queries_Used__c = 0,
            DML_Statements_Used__c = 0, Actions_Count__c = 0
        );
        insert session;

        Test.startTest();
        AgentGovContext.startTracking(reg.Id, session.Id);
        // Do a query to generate delta
        Integer cnt = [SELECT COUNT() FROM AgentGov_Registration__c];
        AgentGovBudgetManager.BudgetResult result = AgentGovContext.stopTracking();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return result');
    }

    // Test action implementation
    private class TestAction implements AgentGovContext.AgentGovAction {
        public void execute() {
            // Perform a SOQL query inside governed context
            List<AgentGov_Registration__c> regs = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        }
    }
}
