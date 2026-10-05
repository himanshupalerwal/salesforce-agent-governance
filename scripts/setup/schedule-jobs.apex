// Schedules AgentGov's three background jobs: the daily budget reset at midnight, the health
// check every hour, and the cleanup on Sunday at 02:00. Safe to run again: jobs already scheduled
// under these three names are replaced, not duplicated. A copy scheduled under a name of your own
// is left as it is.
//
//   sf apex run --file scripts/setup/schedule-jobs.apex --target-org <alias>
AgentGovJobScheduler.scheduleAll();
