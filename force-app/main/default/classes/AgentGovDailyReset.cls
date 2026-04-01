/**
 * @description Scheduled job that resets daily governor budgets for all active agents.
 *              Schedule to run at midnight: System.schedule('AgentGov Daily Reset', '0 0 0 * * ?', new AgentGovDailyReset());
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovDailyReset implements Schedulable {

    public void execute(SchedulableContext ctx) {
        AgentGovBudgetManager.resetDailyBudgets();
    }
}
