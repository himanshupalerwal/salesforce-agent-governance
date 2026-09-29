/**
 * @description Tests for scheduling AgentGov's background jobs.
 */
@IsTest
private class AgentGovJobSchedulerTest {
    private static Map<String, String> scheduledExpressions() {
        Map<String, String> byName = new Map<String, String>();
        for (CronTrigger job : [
            SELECT CronJobDetail.Name, CronExpression
            FROM CronTrigger
            WHERE CronJobDetail.Name LIKE 'AgentGov %'
        ]) {
            byName.put(job.CronJobDetail.Name, job.CronExpression);
        }
        return byName;
    }

    @IsTest
    static void scheduleAllUsesTheDocumentedSchedules() {
        Test.startTest();
        AgentGovJobScheduler.scheduleAll();
        Test.stopTest();

        Map<String, String> jobs = scheduledExpressions();
        Assert.areEqual(3, jobs.size());
        Assert.areEqual(AgentGovConstants.CRON_DAILY_RESET, jobs.get(AgentGovConstants.JOB_DAILY_RESET));
        Assert.areEqual(AgentGovConstants.CRON_HEALTH_CHECK, jobs.get(AgentGovConstants.JOB_HEALTH_CHECK));
        Assert.areEqual(AgentGovConstants.CRON_CLEANUP, jobs.get(AgentGovConstants.JOB_CLEANUP));
    }

    @IsTest
    static void schedulingAgainReplacesRatherThanDuplicates() {
        Test.startTest();
        AgentGovJobScheduler.scheduleAll();
        AgentGovJobScheduler.scheduleAll();
        Test.stopTest();

        Assert.areEqual(3, scheduledExpressions().size());
    }

    @IsTest
    static void unscheduleAllRemovesTheJobsAndStatusSaysSo() {
        Test.startTest();
        AgentGovJobScheduler.scheduleAll();
        Integer removed = AgentGovJobScheduler.unscheduleAll();
        Test.stopTest();

        Assert.areEqual(3, removed);
        Assert.isTrue(scheduledExpressions().isEmpty());
        for (AgentGovJobScheduler.JobStatus status : AgentGovJobScheduler.getJobStatus()) {
            Assert.isFalse(status.scheduled, status.name + ' reports as not scheduled');
        }
    }
}
