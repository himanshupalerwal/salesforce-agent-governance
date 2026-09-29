// Schedules AgentGov's three background jobs: the daily budget reset at midnight, the health
// check every hour, and the cleanup on Sunday at 02:00. Safe to run again: existing AgentGov
// jobs are replaced, not duplicated.
//
//   sf apex run --file scripts/setup/schedule-jobs.apex --target-org <alias>
AgentGovJobScheduler.scheduleAll();
