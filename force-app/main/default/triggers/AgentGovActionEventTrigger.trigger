/**
 * @description Persists AgentGov_Action_Event__e events as AgentGov_Action_Log__c rows.
 *              All logic lives in AgentGovTriggerHandler.
 */
trigger AgentGovActionEventTrigger on AgentGov_Action_Event__e(after insert) {
    AgentGovTriggerHandler.handleActionEvents(Trigger.new);
}
