/**
 * @description Schedules and unschedules AgentGov's three background jobs with the documented
 *              schedules: the daily budget reset at midnight, the health check every hour, and
 *              the cleanup on Sunday at 02:00. Jobs are found by those three names, so running
 *              scheduleAll again replaces them instead of adding duplicates, and a copy scheduled
 *              under another name is left alone. Schedule the jobs after a deploy, not before: a
 *              scheduled job blocks the deploy of every class it uses.
 *
 *              Security posture: inherited sharing. The job lookup goes through AgentGovSelector.
 *              Scheduling requires a user who is allowed to schedule Apex.
 */
public inherited sharing class AgentGovJobScheduler {
    /** @description State of one AgentGov job, for the console's setup checklist. */
    public class JobStatus {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Boolean scheduled;
        @AuraEnabled
        public String cronExpression;
        @AuraEnabled
        public DateTime nextFireTime;
    }

    /**
     * @description Schedules the three jobs, replacing any already scheduled under their names.
     * @return The Ids of the scheduled jobs
     */
    public static List<Id> scheduleAll() {
        unscheduleAll();
        return new List<Id>{
            System.schedule(
                AgentGovConstants.JOB_DAILY_RESET,
                AgentGovConstants.CRON_DAILY_RESET,
                new AgentGovDailyReset()
            ),
            System.schedule(
                AgentGovConstants.JOB_HEALTH_CHECK,
                AgentGovConstants.CRON_HEALTH_CHECK,
                new AgentGovHealthCheck()
            ),
            System.schedule(AgentGovConstants.JOB_CLEANUP, AgentGovConstants.CRON_CLEANUP, new AgentGovCleanup())
        };
    }

    /**
     * @description Removes the jobs scheduled under the three AgentGov names. Before a deploy, run
     *              scripts/setup/unschedule-jobs.apex instead: the platform refuses to replace a
     *              class that any scheduled job uses, and the script also finds copies scheduled
     *              under other names by the class they run.
     * @return The number of jobs removed
     */
    public static Integer unscheduleAll() {
        List<CronTrigger> jobs = AgentGovSelector.getScheduledJobs(jobNames());
        for (CronTrigger job : jobs) {
            System.abortJob(job.Id);
        }
        return jobs.size();
    }

    /**
     * @description Reports whether each AgentGov job is scheduled and when it runs next.
     * @return One status per job, in the documented order
     */
    public static List<JobStatus> getJobStatus() {
        Map<String, CronTrigger> byName = new Map<String, CronTrigger>();
        for (CronTrigger job : AgentGovSelector.getScheduledJobs(jobNames())) {
            byName.put(job.CronJobDetail.Name, job);
        }
        List<JobStatus> statuses = new List<JobStatus>();
        for (String name : jobNames()) {
            JobStatus status = new JobStatus();
            status.name = name;
            CronTrigger job = byName.get(name);
            status.scheduled = job != null;
            status.cronExpression = job?.CronExpression;
            status.nextFireTime = job?.NextFireTime;
            statuses.add(status);
        }
        return statuses;
    }

    private static List<String> jobNames() {
        return new List<String>{
            AgentGovConstants.JOB_DAILY_RESET,
            AgentGovConstants.JOB_HEALTH_CHECK,
            AgentGovConstants.JOB_CLEANUP
        };
    }
}
