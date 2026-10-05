/**
 * @description Tests for AgentGovConflictResolver: locking, priority resolution, and logging.
 */
@IsTest
private class AgentGovConflictResolverTest {
    private static final String RECORD = '001000000000001AAA';

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    private static AgentGov_Registration__c agentWithPriority(String name, Integer priority) {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(name, 'Agentforce', false);
        reg.Priority__c = priority;
        insert reg;
        return reg;
    }

    @IsTest
    static void firstAgentTakesTheLockAndKeepsIt() {
        AgentGov_Registration__c agent = AgentGovTestDataFactory.createRegistration('Agent 1', 'Agentforce', true);

        Assert.isFalse(AgentGovConflictResolver.checkForConflict(agent.Id, RECORD, 'Account').hasConflict);
        Assert.isFalse(
            AgentGovConflictResolver.checkForConflict(agent.Id, RECORD, 'Account').hasConflict,
            'Same agent, no conflict'
        );
        Assert.isTrue(AgentGovConflictResolver.isRecordLocked(RECORD, 'Account'));
        Assert.areEqual(agent.Id, AgentGovConflictResolver.getLockHolder(RECORD, 'Account'));
    }

    @IsTest
    static void higherPriorityAgentOverridesAndConflictIsLogged() {
        AgentGov_Registration__c high = agentWithPriority('High Priority', 1);
        AgentGov_Registration__c low = agentWithPriority('Low Priority', 5);
        AgentGovConflictResolver.checkForConflict(low.Id, RECORD, 'Account');

        AgentGovConflictResolver.ConflictResult result = AgentGovConflictResolver.checkForConflict(
            high.Id,
            RECORD,
            'Account'
        );

        Assert.isTrue(result.hasConflict);
        Assert.areEqual(high.Id, result.winningAgentId);
        Assert.areEqual(AgentGovConstants.RESOLUTION_AGENT1_WON, result.resolution);
        Assert.areEqual(
            1,
            [
                SELECT COUNT()
                FROM AgentGov_Conflict_Log__c
                WHERE Conflict_Type__c = :AgentGovConstants.CONFLICT_PRIORITY_OVERRIDE
            ]
        );
    }

    @IsTest
    static void lowerPriorityAgentIsRefusedAndAssertThrows() {
        AgentGov_Registration__c high = agentWithPriority('High Priority', 1);
        AgentGov_Registration__c low = agentWithPriority('Low Priority', 5);
        AgentGovConflictResolver.checkForConflict(high.Id, RECORD, 'Account');

        AgentGovConflictResolver.ConflictResult result = AgentGovConflictResolver.checkForConflict(
            low.Id,
            RECORD,
            'Account'
        );
        Assert.isTrue(result.hasConflict);
        Assert.areEqual(high.Id, result.winningAgentId);
        Assert.areEqual(AgentGovConstants.RESOLUTION_AGENT2_WON, result.resolution, 'The lock holder keeps the record');

        try {
            AgentGovConflictResolver.assertNoConflict(low.Id, RECORD, 'Account');
            Assert.fail('The lower-priority agent must be refused');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.RECORD_LOCKED, e.getErrorCode());
        }
        AgentGovConflictResolver.assertNoConflict(high.Id, RECORD, 'Account');
    }

    @IsTest
    static void releaseAndClearLocks() {
        AgentGov_Registration__c agent = AgentGovTestDataFactory.createRegistration('Agent 1', 'Agentforce', true);
        AgentGovConflictResolver.checkForConflict(agent.Id, RECORD, 'Account');

        AgentGovConflictResolver.releaseRecord(agent.Id, RECORD, 'Account');
        Assert.isFalse(AgentGovConflictResolver.isRecordLocked(RECORD, 'Account'));

        AgentGovConflictResolver.checkForConflict(agent.Id, RECORD, 'Account');
        AgentGovConflictResolver.clearAllLocks();
        Assert.isFalse(AgentGovConflictResolver.isRecordLocked(RECORD, 'Account'));
    }

    @IsTest
    static void detectionCanBeDisabled() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Enable_Conflict_Detection__c = false;
        update settings;
        AgentGovSelector.clearCache();
        AgentGov_Registration__c agent = AgentGovTestDataFactory.createRegistration('Agent', 'Agentforce', true);

        AgentGovConflictResolver.ConflictResult result = AgentGovConflictResolver.checkForConflict(
            agent.Id,
            RECORD,
            'Account'
        );

        Assert.isFalse(result.hasConflict);
        Assert.isFalse(
            AgentGovConflictResolver.isRecordLocked(RECORD, 'Account'),
            'No lock is taken when detection is off'
        );
    }

    @IsTest
    static void unknownAgentsResolveAsFailed() {
        AgentGov_Registration__c agent = AgentGovTestDataFactory.createRegistration('Agent', 'Agentforce', true);
        Id unknownId = AgentGov_Registration__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';
        AgentGovConflictResolver.checkForConflict(unknownId, RECORD, 'Account');

        AgentGovConflictResolver.ConflictResult result = AgentGovConflictResolver.checkForConflict(
            agent.Id,
            RECORD,
            'Account'
        );

        Assert.isTrue(result.hasConflict);
        Assert.areEqual(AgentGovConstants.RESOLUTION_FAILED, result.resolution);
    }
}
