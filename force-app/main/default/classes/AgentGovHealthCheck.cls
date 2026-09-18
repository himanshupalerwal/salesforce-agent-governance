/**
 * @description Scheduled job that keeps agent state moving when no requests arrive:
 *              OPEN circuit breakers whose cooldown has elapsed become HALF_OPEN, and
 *              sessions that have stayed active for too long are terminated.
 *              Schedule: System.schedule('AgentGov Health Check', '0 0 * * * ?', new AgentGovHealthCheck());
 *
 *              Security posture: inherited sharing. Reads go through AgentGovSelector and
 *              writes through AgentGovDml and AgentGovCircuitBreaker, all in system mode.
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

        List<AgentGov_Session__c> orphanedSessions = AgentGovSelector.getOrphanedSessions(
            AgentGovConstants.ORPHAN_SESSION_HOURS
        );
        if (!orphanedSessions.isEmpty()) {
            DateTime now = DateTime.now();
            for (AgentGov_Session__c session : orphanedSessions) {
                session.Status__c = AgentGovConstants.SESSION_TERMINATED;
                session.Session_End__c = now;
            }
            AgentGovDml.assertAllSucceeded(
                AgentGovDml.updateRecords(orphanedSessions, false),
                'Orphaned session cleanup'
            );
        }
    }
}
