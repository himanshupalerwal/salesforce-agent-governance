/**
 * @description Maintains the unique Active_Session_Key__c on agent sessions so that an agent
 *              can have at most one active session, whichever path creates it.
 *              All logic lives in AgentGovTriggerHandler.
 */
trigger AgentGovSessionTrigger on AgentGov_Session__c(before insert, before update) {
    AgentGovTriggerHandler.populateSessionKeys(Trigger.new);
}
