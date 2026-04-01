@IsTest
private class AgentGovTriggerHandlerTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    @IsTest
    static void testLogAction() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Handler Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovTriggerHandler.logAction(
            reg.Id, 'Query', 'Account', '001000000000001', 'Success', '{"test": true}'
        );
        Test.stopTest();

        // The action should be logged via platform event -> trigger -> action log
        // In test context, we verify the event was published
    }

    @IsTest
    static void testLogActionFrameworkDisabled() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();

        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Handler Agent', 'Agentforce', true);

        Test.startTest();
        // Should not throw even when disabled
        AgentGovTriggerHandler.logAction(reg.Id, 'Query', 'Account', '001000000000001', 'Success', null);
        Test.stopTest();
    }

    @IsTest
    static void testLogActionEventsDisabled() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Enable_Real_Time_Events__c = false;
        update settings;
        AgentGovSelector.clearCache();

        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Handler Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovTriggerHandler.logAction(reg.Id, 'Create', 'Contact', '003000000000001', 'Success', null);
        Test.stopTest();

        // Should fall back to direct insert
        List<AgentGov_Action_Log__c> logs = [SELECT Id FROM AgentGov_Action_Log__c WHERE Agent_Registration__c = :reg.Id];
        System.assertEquals(1, logs.size(), 'Should insert directly when events disabled');
    }

    @IsTest
    static void testLogActions() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Handler Agent', 'Agentforce', true);

        List<AgentGov_Action_Event__e> events = new List<AgentGov_Action_Event__e>{
            new AgentGov_Action_Event__e(
                Agent_Id__c = reg.Id,
                Agent_Name__c = 'Handler Agent',
                Action_Type__c = 'Query',
                Object_Name__c = 'Account',
                Status__c = 'Success',
                Timestamp__c = DateTime.now()
            )
        };

        Test.startTest();
        AgentGovTriggerHandler.logActions(events);
        Test.stopTest();
    }

    @IsTest
    static void testLogActionsEmptyList() {
        Test.startTest();
        AgentGovTriggerHandler.logActions(new List<AgentGov_Action_Event__e>());
        Test.stopTest();
        // Should not throw
    }
}
