/**
 * @description Delivers AgentGov_Alert__e events to the configured administrator email.
 *              All logic lives in AgentGovTriggerHandler.
 */
trigger AgentGovAlertTrigger on AgentGov_Alert__e(after insert) {
    AgentGovTriggerHandler.handleAlerts(Trigger.new);
}
