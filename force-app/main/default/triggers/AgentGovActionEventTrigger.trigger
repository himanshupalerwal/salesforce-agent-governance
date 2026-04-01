/**
 * @description Trigger on AgentGov_Action_Event__e platform event.
 *              Creates AgentGov_Action_Log__c records for audit trail.
 */
trigger AgentGovActionEventTrigger on AgentGov_Action_Event__e (after insert) {
    List<AgentGov_Action_Log__c> logs = new List<AgentGov_Action_Log__c>();

    for (AgentGov_Action_Event__e evt : Trigger.New) {
        AgentGov_Action_Log__c log = new AgentGov_Action_Log__c(
            Action_Type__c = evt.Action_Type__c,
            Object_Name__c = evt.Object_Name__c,
            Record_Id__c = evt.Record_Id__c,
            Status__c = evt.Status__c,
            Timestamp__c = evt.Timestamp__c != null ? evt.Timestamp__c : DateTime.now(),
            Details__c = evt.Details__c
        );

        // Set agent registration lookup if valid ID
        if (String.isNotBlank(evt.Agent_Id__c)) {
            try {
                log.Agent_Registration__c = (Id) evt.Agent_Id__c;
            } catch (Exception e) {
                log.Details__c = (log.Details__c != null ? log.Details__c + '\n' : '') + 'Invalid Agent_Id: ' + evt.Agent_Id__c;
            }
        }

        logs.add(log);
    }

    if (!logs.isEmpty()) {
        Database.insert(logs, false);
    }
}
