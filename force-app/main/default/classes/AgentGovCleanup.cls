/**
 * @description Batch job that purges old Agent Action Log records based on retention settings.
 *              Run manually or schedule: Database.executeBatch(new AgentGovCleanup(), 2000);
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovCleanup implements Database.Batchable<SObject>, Database.Stateful {

    private Integer totalDeleted = 0;
    private Integer retentionDays;

    public AgentGovCleanup() {
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        this.retentionDays = settings.Log_Retention_Days__c != null
            ? (Integer) settings.Log_Retention_Days__c
            : AgentGovConstants.DEFAULT_LOG_RETENTION_DAYS;
    }

    public AgentGovCleanup(Integer retentionDays) {
        this.retentionDays = retentionDays;
    }

    public Database.QueryLocator start(Database.BatchableContext ctx) {
        DateTime cutoff = DateTime.now().addDays(-this.retentionDays);
        return Database.getQueryLocator([
            SELECT Id FROM AgentGov_Action_Log__c
            WHERE Timestamp__c < :cutoff
            ORDER BY Timestamp__c ASC
        ]);
    }

    public void execute(Database.BatchableContext ctx, List<AgentGov_Action_Log__c> scope) {
        Database.DeleteResult[] results = Database.delete(scope, false);
        for (Database.DeleteResult dr : results) {
            if (dr.isSuccess()) {
                totalDeleted++;
            }
        }
    }

    public void finish(Database.BatchableContext ctx) {
        System.debug(LoggingLevel.INFO, 'AgentGov Cleanup: Deleted ' + totalDeleted + ' action log records older than ' + retentionDays + ' days.');
    }
}
