/**
 * @description Sets the unique per-agent-per-day key on Governor Budget rows so that no two
 *              rows can exist for the same agent and date, whichever path creates them.
 *              All logic lives in AgentGovTriggerHandler.
 */
trigger AgentGovBudgetTrigger on AgentGov_Budget__c(before insert, before update) {
    AgentGovTriggerHandler.populateBudgetKeys(Trigger.new);
}
