/**
 * @description Batch job that purges framework records older than their retention period, one
 *              object after another: action logs, conflict logs, and finished sessions follow
 *              AgentGov_Settings__c.Log_Retention_Days__c, and daily budget rows follow
 *              Budget_Retention_Days__c, which defaults longer because the console's usage
 *              history is read from them. Each object is a separate batch run chained from the
 *              previous one's finish, and each writes a System log entry summarising its purge.
 *
 *              The class is both Batchable and Schedulable, so it can be run immediately or
 *              scheduled on a recurring basis:
 *
 *              Database.executeBatch(new AgentGovCleanup(), 2000);
 *              System.schedule('AgentGov Cleanup', '0 0 2 ? * SUN', new AgentGovCleanup());
 *
 *              Security posture: without sharing, with the queries and deletes in system mode,
 *              because a purge must cover every row regardless of who scheduled the job.
 */
@SuppressWarnings('PMD.ApexSharingViolations')
public without sharing class AgentGovCleanup implements Database.Batchable<SObject>, Database.Stateful, Schedulable {
    /** @description Records deleted per batch execution. Matches the platform maximum for a delete. */
    @TestVisible
    private static final Integer BATCH_SIZE = 2000;

    /** @description The purge phases, in the order they run. */
    public enum Phase {
        ACTION_LOGS,
        CONFLICT_LOGS,
        SESSIONS,
        BUDGETS
    }

    private Phase currentPhase;
    private Integer totalDeleted = 0;
    private Integer totalFailed = 0;
    private Integer retentionDays;
    private Integer appliedDays;

    /**
     * @description Uses the retention periods from settings, resolved when the job runs.
     *
     *              Scheduled Apex serializes the instance at System.schedule time, so reading
     *              the setting in the constructor would freeze whatever value was configured
     *              on the day the job was scheduled and ignore every later change.
     */
    public AgentGovCleanup() {
        this(Phase.ACTION_LOGS, null);
    }

    /**
     * @description Uses an explicit retention period for logs, conflicts, and sessions.
     *              Budget rows still follow their own setting.
     * @param retentionDays Rows older than this many days are purged
     */
    public AgentGovCleanup(Integer retentionDays) {
        this(Phase.ACTION_LOGS, retentionDays);
    }

    @TestVisible
    private AgentGovCleanup(Phase startAt, Integer retentionDays) {
        this.currentPhase = startAt;
        this.retentionDays = retentionDays;
    }

    /**
     * @description Starts the purge from a scheduled run.
     * @param ctx Schedulable context, unused
     */
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new AgentGovCleanup(Phase.ACTION_LOGS, this.retentionDays), BATCH_SIZE);
    }

    /** @description Selects the rows of the current phase to purge. */
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        if (this.retentionDays == null) {
            this.retentionDays = settings.Log_Retention_Days__c != null
                ? (Integer) settings.Log_Retention_Days__c
                : AgentGovConstants.DEFAULT_LOG_RETENTION_DAYS;
        }
        this.appliedDays = this.retentionDays;
        DateTime cutoff = DateTime.now().addDays(-this.retentionDays);
        switch on this.currentPhase {
            when ACTION_LOGS {
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
            when CONFLICT_LOGS {
                return Database.getQueryLocator(
                    [SELECT Id FROM AgentGov_Conflict_Log__c WHERE Timestamp__c < :cutoff WITH SYSTEM_MODE]
                );
            }
            when SESSIONS {
                // Only finished sessions; an active one is closed by the health check first.
                return Database.getQueryLocator(
                    [
                        SELECT Id
                        FROM AgentGov_Session__c
                        WHERE
                            Status__c != :AgentGovConstants.SESSION_ACTIVE
                            AND (Session_End__c < :cutoff
                            OR (Session_End__c = NULL
                            AND Session_Start__c < :cutoff))
                        WITH SYSTEM_MODE
                    ]
                );
            }
            when else {
                this.appliedDays = settings.Budget_Retention_Days__c != null
                    ? (Integer) settings.Budget_Retention_Days__c
                    : AgentGovConstants.DEFAULT_BUDGET_RETENTION_DAYS;
                Date budgetCutoff = AgentGovBudgetManager.budgetDate().addDays(-this.appliedDays);
                return Database.getQueryLocator(
                    [SELECT Id FROM AgentGov_Budget__c WHERE Budget_Date__c < :budgetCutoff WITH SYSTEM_MODE]
                );
            }
        }
    }

    /** @description Deletes one batch of rows. */
    public void execute(Database.BatchableContext ctx, List<SObject> scope) {
        for (Database.DeleteResult result : AgentGovDml.deleteRecords(scope, false)) {
            if (result.isSuccess()) {
                totalDeleted++;
            } else {
                totalFailed++;
            }
        }
    }

    /** @description Records a summary of this phase's purge and starts the next phase. */
    public void finish(Database.BatchableContext ctx) {
        AgentGovTriggerHandler.recordFrameworkEvent(
            null,
            totalFailed == 0 ? AgentGovConstants.ACTION_SUCCESS : AgentGovConstants.ACTION_FAILURE,
            phaseLabel() +
                ' purge: deleted ' +
                totalDeleted +
                ' rows older than ' +
                appliedDays +
                ' days; ' +
                totalFailed +
                ' could not be deleted.',
            null
        );
        if (this.currentPhase.ordinal() < Phase.values().size() - 1) {
            Database.executeBatch(
                new AgentGovCleanup(Phase.values()[this.currentPhase.ordinal() + 1], this.retentionDays),
                BATCH_SIZE
            );
        }
    }

    private String phaseLabel() {
        switch on this.currentPhase {
            when ACTION_LOGS {
                return 'Action log';
            }
            when CONFLICT_LOGS {
                return 'Conflict log';
            }
            when SESSIONS {
                return 'Session';
            }
            when else {
                return 'Budget';
            }
        }
    }
}
