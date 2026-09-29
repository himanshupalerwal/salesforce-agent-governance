/**
 * @description Scheduled job that keeps agent state moving when no requests arrive:
 *              OPEN circuit breakers whose cooldown has elapsed become HALF_OPEN, and sessions
 *              that have gone idle or run past the maximum duration are closed, with their end
 *              time set to their last activity.
 *              Schedule: AgentGovJobScheduler.scheduleAll(), or
 *              System.schedule('AgentGov Health Check', '0 0 * * * ?', new AgentGovHealthCheck());
 *
 *              Security posture: inherited sharing. Reads go through AgentGovSelector and
 *              writes through AgentGovDml, AgentGovCircuitBreaker and AgentGovSessionTracker,
 *              all in system mode.
 */
public inherited sharing class AgentGovHealthCheck implements Schedulable {
    /**
     * @description Runs one health-check pass.
     * @param ctx Schedulable context, unused
     */
    public void execute(SchedulableContext ctx) {
        List<AgentGov_Registration__c> openAgents = AgentGovSelector.getOpenAgentsPastCooldown();
        if (!openAgents.isEmpty()) {
            AgentGovCircuitBreaker.transitionToHalfOpen(openAgents);
        }
        // Bounded per run so a large backlog cannot exceed the DML row limit; the rest are
        // closed by the next hourly run.
        AgentGovSessionTracker.closeStale(AgentGovConstants.MAX_SESSIONS_CLOSED_PER_RUN);
    }
}
