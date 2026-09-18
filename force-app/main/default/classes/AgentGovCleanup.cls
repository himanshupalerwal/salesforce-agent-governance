/**
 * @description Batch job that purges action log rows older than the configured retention.
 *              A System log entry summarising the purge is written when the job finishes.
 *
 *              The class is both Batchable and Schedulable, so it can be run immediately
 *              or scheduled on a recurring basis with the same command shape as the other
 *              two jobs:
 *
 *              Database.executeBatch(new AgentGovCleanup(), 2000);
 *              System.schedule('AgentGov Cleanup', '0 0 2 ? * SUN', new AgentGovCleanup());
 *
 *              Security posture: without sharing, with the query and delete in system mode,
 *              because a purge must cover every row regardless of who scheduled the job.
 */
@SuppressWarnings('PMD.ApexSharingViolations')
public without sharing class AgentGovCleanup implements Database.Batchable<SObject>, Database.Stateful, Schedulable {
    /** @description Records deleted per batch execution. Matches the platform maximum for a delete. */
    @TestVisible
    private static final Integer BATCH_SIZE = 2000;

    private Integer totalDeleted = 0;
    private Integer totalFailed = 0;
    private Integer retentionDays;

    /**
     * @description Uses the retention period from settings, resolved when the job runs.
     *
     *              Scheduled Apex serializes the instance at System.schedule time, so reading
     *              the setting in the constructor would freeze whatever value was configured
     *              on the day the job was scheduled and ignore every later change.
     */
    public AgentGovCleanup() {
        this.retentionDays = null;
    }

    /**
     * @description Uses an explicit retention period.
     * @param retentionDays Rows older than this many days are purged
     */
    public AgentGovCleanup(Integer retentionDays) {
        this.retentionDays = retentionDays;
    }

    /**
     * @description Starts the purge from a scheduled run.
     * @param ctx Schedulable context, unused
     */
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(this, BATCH_SIZE);
    }

    /** @description Selects the rows to purge. */
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        if (this.retentionDays == null) {
            AgentGov_Settings__c settings = AgentGovSelector.getSettings();
            this.retentionDays = settings.Log_Retention_Days__c != null
                ? (Integer) settings.Log_Retention_Days__c
                : AgentGovConstants.DEFAULT_LOG_RETENTION_DAYS;
        }
        DateTime cutoff = DateTime.now().addDays(-this.retentionDays);
        return Database.getQueryLocator(
            [
                SELECT Id
                FROM AgentGov_Action_Log__c
                WHERE Timestamp__c < :cutoff
                WITH SYSTEM_MODE
                ORDER BY Timestamp__c ASC
            ]
        );
    }

    /** @description Deletes one batch of rows. */
    public void execute(Database.BatchableContext ctx, List<AgentGov_Action_Log__c> scope) {
        for (Database.DeleteResult result : AgentGovDml.deleteRecords(scope, false)) {
            if (result.isSuccess()) {
                totalDeleted++;
            } else {
                totalFailed++;
            }
        }
    }

    /** @description Records a summary of the purge. */
    public void finish(Database.BatchableContext ctx) {
        AgentGovTriggerHandler.recordFrameworkEvent(
            null,
            totalFailed == 0 ? AgentGovConstants.ACTION_SUCCESS : AgentGovConstants.ACTION_FAILURE,
            'Action log purge: deleted ' +
                totalDeleted +
                ' rows older than ' +
                retentionDays +
                ' days; ' +
                totalFailed +
                ' could not be deleted.',
            null
        );
    }
}
