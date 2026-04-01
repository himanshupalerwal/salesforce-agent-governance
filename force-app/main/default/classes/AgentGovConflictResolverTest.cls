@IsTest
private class AgentGovConflictResolverTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    @IsTest
    static void testNoConflict() {
        AgentGov_Registration__c agent1 = AgentGovTestDataFactory.createRegistration('Agent 1', 'Agentforce', true);

        Test.startTest();
        AgentGovConflictResolver.ConflictResult result = AgentGovConflictResolver.checkForConflict(
            agent1.Id, '001000000000001', 'Account'
        );
        Test.stopTest();

        System.assertEquals(false, result.hasConflict, 'Should not detect conflict');
    }

    @IsTest
    static void testSameAgentNoConflict() {
        AgentGov_Registration__c agent1 = AgentGovTestDataFactory.createRegistration('Agent 1', 'Agentforce', true);

        // Lock record first
        AgentGovConflictResolver.checkForConflict(agent1.Id, '001000000000001', 'Account');

        Test.startTest();
        // Same agent checks again
        AgentGovConflictResolver.ConflictResult result = AgentGovConflictResolver.checkForConflict(
            agent1.Id, '001000000000001', 'Account'
        );
        Test.stopTest();

        System.assertEquals(false, result.hasConflict, 'Same agent should not conflict');
    }

    @IsTest
    static void testConflictHigherPriorityWins() {
        AgentGov_Registration__c agent1 = AgentGovTestDataFactory.createRegistration('High Priority', 'Agentforce', false);
        agent1.Priority__c = 1;
        insert agent1;

        AgentGov_Registration__c agent2 = AgentGovTestDataFactory.createRegistration('Low Priority', 'Custom_Apex', false);
        agent2.Priority__c = 5;
        agent2.API_Key__c = 'key-low';
        insert agent2;

        // Agent 2 locks the record
        AgentGovConflictResolver.checkForConflict(agent2.Id, '001000000000001', 'Account');

        Test.startTest();
        // Agent 1 (higher priority) tries to access
        AgentGovConflictResolver.ConflictResult result = AgentGovConflictResolver.checkForConflict(
            agent1.Id, '001000000000001', 'Account'
        );
        Test.stopTest();

        System.assertEquals(true, result.hasConflict, 'Should detect conflict');
        System.assertEquals(agent1.Id, result.winningAgentId, 'Higher priority should win');
    }

    @IsTest
    static void testConflictLowerPriorityQueued() {
        AgentGov_Registration__c agent1 = AgentGovTestDataFactory.createRegistration('High Priority', 'Agentforce', false);
        agent1.Priority__c = 1;
        insert agent1;

        AgentGov_Registration__c agent2 = AgentGovTestDataFactory.createRegistration('Low Priority', 'Custom_Apex', false);
        agent2.Priority__c = 5;
        agent2.API_Key__c = 'key-low2';
        insert agent2;

        // Agent 1 locks the record
        AgentGovConflictResolver.checkForConflict(agent1.Id, '001000000000002', 'Account');

        Test.startTest();
        // Agent 2 (lower priority) tries
        AgentGovConflictResolver.ConflictResult result = AgentGovConflictResolver.checkForConflict(
            agent2.Id, '001000000000002', 'Account'
        );
        Test.stopTest();

        System.assertEquals(true, result.hasConflict);
        System.assertEquals(agent1.Id, result.winningAgentId, 'Lock holder with higher priority should keep lock');
    }

    @IsTest
    static void testReleaseRecord() {
        AgentGov_Registration__c agent1 = AgentGovTestDataFactory.createRegistration('Agent 1', 'Agentforce', true);
        AgentGovConflictResolver.checkForConflict(agent1.Id, '001000000000003', 'Account');

        System.assertEquals(true, AgentGovConflictResolver.isRecordLocked('001000000000003', 'Account'));

        Test.startTest();
        AgentGovConflictResolver.releaseRecord(agent1.Id, '001000000000003', 'Account');
        Test.stopTest();

        System.assertEquals(false, AgentGovConflictResolver.isRecordLocked('001000000000003', 'Account'));
    }

    @IsTest
    static void testGetLockHolder() {
        AgentGov_Registration__c agent1 = AgentGovTestDataFactory.createRegistration('Agent 1', 'Agentforce', true);
        AgentGovConflictResolver.checkForConflict(agent1.Id, '001000000000004', 'Account');

        Test.startTest();
        Id holder = AgentGovConflictResolver.getLockHolder('001000000000004', 'Account');
        Test.stopTest();

        System.assertEquals(agent1.Id, holder);
    }

    @IsTest
    static void testConflictDetectionDisabled() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Enable_Conflict_Detection__c = false;
        update settings;
        AgentGovSelector.clearCache();

        AgentGov_Registration__c agent1 = AgentGovTestDataFactory.createRegistration('Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovConflictResolver.ConflictResult result = AgentGovConflictResolver.checkForConflict(
            agent1.Id, '001000000000005', 'Account'
        );
        Test.stopTest();

        System.assertEquals(false, result.hasConflict, 'Should not detect when disabled');
    }

    @IsTest
    static void testClearAllLocks() {
        AgentGov_Registration__c agent1 = AgentGovTestDataFactory.createRegistration('Agent', 'Agentforce', true);
        AgentGovConflictResolver.checkForConflict(agent1.Id, '001000000000006', 'Account');

        Test.startTest();
        AgentGovConflictResolver.clearAllLocks();
        Test.stopTest();

        System.assertEquals(false, AgentGovConflictResolver.isRecordLocked('001000000000006', 'Account'));
    }
}
