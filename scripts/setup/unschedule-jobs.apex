// Removes AgentGov's scheduled jobs. Run it before deploying a new version: the platform
// refuses to replace an Apex class that a scheduled job uses. Self-contained on purpose, so it
// works whichever AgentGov version is installed. Schedule the jobs again after the deploy with
// scripts/setup/schedule-jobs.apex, and recreate any extra copies you had scheduled under names
// of your own; the log lists every job removed.
//
//   sf apex run --file scripts/setup/unschedule-jobs.apex --target-org <alias>
List<String> jobNames = new List<String>{ 'AgentGov Daily Reset', 'AgentGov Health Check', 'AgentGov Cleanup' };
List<String> jobClasses = new List<String>{ 'AgentGovDailyReset', 'AgentGovHealthCheck', 'AgentGovCleanup' };
Set<Id> jobIds = new Set<Id>();
for (CronTrigger job : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name IN :jobNames]) {
    jobIds.add(job.Id);
}
// A copy scheduled under another name, such as a second health check at half past the hour,
// blocks the deploy just the same, so jobs are also found by the class they run.
for (AsyncApexJob job : [
    SELECT CronTriggerId
    FROM AsyncApexJob
    WHERE JobType = 'ScheduledApex' AND ApexClass.Name IN :jobClasses AND CronTriggerId != NULL
]) {
    jobIds.add(job.CronTriggerId);
}
List<String> removed = new List<String>();
for (CronTrigger job : [SELECT Id, CronJobDetail.Name FROM CronTrigger WHERE Id IN :jobIds]) {
    System.abortJob(job.Id);
    removed.add(job.CronJobDetail.Name);
}
System.debug(
    LoggingLevel.INFO,
    'Removed ' +
        removed.size() +
        ' AgentGov scheduled job(s)' +
        (removed.isEmpty() ? '.' : ': ' + String.join(removed, ', '))
);
