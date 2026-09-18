/**
 * @description Scheduled job that creates today's budget for every active agent.
 *              Schedule at midnight: System.schedule('AgentGov Daily Reset', '0 0 0 * * ?', new AgentGovDailyReset());
 *              Budgets are also created lazily on first use, so the job is a convenience that
 *              makes the day's rows visible on the dashboard before agents start working.
 *
 *              Security posture: inherited sharing. Writes go through AgentGovBudgetManager in system mode.
 */
public inherited sharing class AgentGovDailyReset implements Schedulable {
    /**
     * @description Runs the reset.
     * @param ctx Schedulable context, unused
     */
    public void execute(SchedulableContext ctx) {
        AgentGovBudgetManager.resetDailyBudgets();
    }
}
