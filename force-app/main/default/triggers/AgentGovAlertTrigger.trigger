/**
 * @description Records each delivered AgentGov_Alert__e as an Alert row in the action log, then
 *              emails the alerts to the administrator address in settings and, when
 *              Notify_Agent_Owners__c is checked, to each affected agent's owner. All logic
 *              lives in AgentGovTriggerHandler.
 */
trigger AgentGovAlertTrigger on AgentGov_Alert__e(after insert) {
    AgentGovTriggerHandler.handleAlerts(Trigger.new);
}
