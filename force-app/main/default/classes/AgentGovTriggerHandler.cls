/**
 * @description Trigger handler that automatically logs agent-triggered DML operations.
 *              Publishes action events for real-time monitoring and audit trail.
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovTriggerHandler {

    /**
     * @description Logs an agent action by publishing a platform event.
     * @param registrationId The agent registration ID
     * @param actionType The type of action performed
     * @param objectName The object acted upon
     * @param recordId The record ID
     * @param status The action status
     * @param details Optional JSON details
     */
    public static void logAction(Id registrationId, String actionType, String objectName, String recordId, String status, String details) {
        if (!AgentGovSelector.isFrameworkEnabled()) {
            return;
        }

        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        if (settings.Enable_Real_Time_Events__c == false) {
            // Fall back to direct insert
            logActionDirect(registrationId, actionType, objectName, recordId, status, details);
            return;
        }

        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById(registrationId);
        String agentName = reg != null ? reg.Agent_Name__c : 'Unknown';

        AgentGov_Action_Event__e evt = new AgentGov_Action_Event__e(
            Agent_Id__c = registrationId,
            Agent_Name__c = agentName,
            Action_Type__c = actionType,
            Object_Name__c = objectName,
            Record_Id__c = recordId,
            Status__c = status,
            Timestamp__c = DateTime.now(),
            Details__c = details
        );

        Database.SaveResult sr = EventBus.publish(evt);
        if (!sr.isSuccess()) {
            System.debug(LoggingLevel.ERROR, 'AgentGov: Event publish failed, falling back to direct insert.');
            logActionDirect(registrationId, actionType, objectName, recordId, status, details);
        }
    }

    /**
     * @description Logs multiple agent actions in bulk.
     * @param events List of action event records to publish
     */
    public static void logActions(List<AgentGov_Action_Event__e> events) {
        if (!AgentGovSelector.isFrameworkEnabled() || events == null || events.isEmpty()) {
            return;
        }

        List<Database.SaveResult> results = EventBus.publish(events);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'AgentGov: Failed to publish event ' + i + ': ' + results[i].getErrors());
            }
        }
    }

    private static void logActionDirect(Id registrationId, String actionType, String objectName, String recordId, String status, String details) {
        try {
            AgentGov_Action_Log__c log = new AgentGov_Action_Log__c(
                Agent_Registration__c = registrationId,
                Action_Type__c = actionType,
                Object_Name__c = objectName,
                Record_Id__c = recordId,
                Status__c = status,
                Timestamp__c = DateTime.now(),
                Details__c = details
            );
            insert log;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AgentGov: Failed to insert action log: ' + e.getMessage());
        }
    }
}
