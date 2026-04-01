@IsTest
private class AgentGovCleanupTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Cleanup Agent', 'Agentforce', true);

        // Create old logs
        List<AgentGov_Action_Log__c> logs = new List<AgentGov_Action_Log__c>();
        for (Integer i = 0; i < 5; i++) {
            logs.add(new AgentGov_Action_Log__c(
                Agent_Registration__c = reg.Id,
                Action_Type__c = 'Query',
                Status__c = 'Success',
                Timestamp__c = DateTime.now().addDays(-100)
            ));
        }
        insert logs;
    }

    @IsTest
    static void testBatchCleanup() {
        Test.startTest();
        AgentGovCleanup batch = new AgentGovCleanup(30);
        Database.executeBatch(batch, 200);
        Test.stopTest();

        List<AgentGov_Action_Log__c> remaining = [SELECT Id FROM AgentGov_Action_Log__c];
        System.assertEquals(0, remaining.size(), 'Old logs should be deleted');
    }

    @IsTest
    static void testBatchCleanupDefaultRetention() {
        Test.startTest();
        AgentGovCleanup batch = new AgentGovCleanup();
        Database.executeBatch(batch, 200);
        Test.stopTest();
    }
}
