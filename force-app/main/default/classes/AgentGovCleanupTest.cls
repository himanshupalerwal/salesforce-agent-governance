/**
 * @description Tests for the action-log purge job.
 */
@IsTest
private class AgentGovCleanupTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Cleanup Agent', 'Agentforce', true);
        List<AgentGov_Action_Log__c> logs = new List<AgentGov_Action_Log__c>();
        for (Integer i = 0; i < 5; i++) {
            logs.add(
                new AgentGov_Action_Log__c(
                    Agent_Registration__c = reg.Id,
                    Action_Type__c = AgentGovConstants.ACTION_QUERY,
                    Status__c = AgentGovConstants.ACTION_SUCCESS,
                    Timestamp__c = DateTime.now().addDays(-100)
                )
            );
        }
        logs.add(
            new AgentGov_Action_Log__c(
                Agent_Registration__c = reg.Id,
                Action_Type__c = AgentGovConstants.ACTION_QUERY,
                Status__c = AgentGovConstants.ACTION_SUCCESS,
                Timestamp__c = DateTime.now().addDays(-10)
            )
        );
        insert logs;
    }

    @IsTest
    static void explicitRetentionPurgesOlderRowsAndRecordsSummary() {
        Test.startTest();
        Database.executeBatch(new AgentGovCleanup(30), 200);
        Test.stopTest();

        Assert.areEqual(
            1,
            [SELECT COUNT() FROM AgentGov_Action_Log__c WHERE Action_Type__c = :AgentGovConstants.ACTION_QUERY],
            'Only the recent row remains'
        );
        List<String> summaries = new List<String>();
        for (AgentGov_Action_Log__c summary : [
            SELECT Details__c
            FROM AgentGov_Action_Log__c
            WHERE Action_Type__c = :AgentGovConstants.ACTION_SYSTEM
        ]) {
            summaries.add(summary.Details__c);
        }
        String all = String.join(summaries, '\n');
        Assert.isTrue(all.contains('Action log purge: deleted 5 rows older than 30 days'), all);
        // Each phase chains the next and records its own summary.
        Assert.areEqual(4, summaries.size(), all);
        Assert.isTrue(all.contains('Budget purge: deleted 0 rows older than'), all);
    }

    @IsTest
    static void defaultRetentionComesFromSettings() {
        Test.startTest();
        Database.executeBatch(new AgentGovCleanup(), 200);
        Test.stopTest();

        Assert.areEqual(
            1,
            [SELECT COUNT() FROM AgentGov_Action_Log__c WHERE Action_Type__c = :AgentGovConstants.ACTION_QUERY],
            'Rows older than the 90-day default are gone; the 10-day-old row survives'
        );
    }

    @IsTest
    static void scheduledEntryPointRunsThePurge() {
        // Calling the Schedulable entry point directly enqueues the batch inside the test
        // context, so stopTest runs it. Going through System.schedule would not, because
        // the platform does not chain a batch queued by a scheduled job in the same test.
        Test.startTest();
        new AgentGovCleanup(30).execute(null);
        Test.stopTest();

        Assert.areEqual(
            1,
            [SELECT COUNT() FROM AgentGov_Action_Log__c WHERE Action_Type__c = :AgentGovConstants.ACTION_QUERY],
            'Only the recent row survives a scheduled purge'
        );
    }

    @IsTest
    static void jobCanBeScheduled() {
        Test.startTest();
        String jobId = System.schedule('AgentGov Cleanup Test', '0 0 2 ? * SUN', new AgentGovCleanup());
        Test.stopTest();

        Assert.isNotNull(jobId, 'The documented System.schedule call compiles and schedules');
    }
}
