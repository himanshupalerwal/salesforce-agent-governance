/**
 * @description Scheduled job that performs periodic health checks on agents.
 *              Transitions OPEN circuit breakers to HALF_OPEN when cooldown expires,
 *              and auto-closes orphaned sessions.
 *              Schedule: System.schedule('AgentGov Health Check', '0 0 * * * ?', new AgentGovHealthCheck());
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovHealthCheck implements Schedulable {

    private static final Integer ORPHAN_SESSION_HOURS = 24;

    public void execute(SchedulableContext ctx) {
        // 1. Transition OPEN circuit breakers past cooldown to HALF_OPEN
        List<AgentGov_Registration__c> openAgents = AgentGovSelector.getOpenAgentsPastCooldown();
        if (!openAgents.isEmpty()) {
            for (AgentGov_Registration__c reg : openAgents) {
                reg.Circuit_Breaker_State__c = AgentGovConstants.CB_HALF_OPEN;
                if (reg.Status__c == AgentGovConstants.STATUS_BLOCKED) {
                    reg.Status__c = AgentGovConstants.STATUS_THROTTLED;
                }
            }
            Database.update(openAgents, false);
        }

        // 2. Auto-close orphaned sessions
        List<AgentGov_Session__c> orphanedSessions = AgentGovSelector.getOrphanedSessions(ORPHAN_SESSION_HOURS);
        if (!orphanedSessions.isEmpty()) {
            for (AgentGov_Session__c session : orphanedSessions) {
                session.Status__c = AgentGovConstants.SESSION_TERMINATED;
                session.Session_End__c = DateTime.now();
            }
            Database.update(orphanedSessions, false);
        }
    }
}
