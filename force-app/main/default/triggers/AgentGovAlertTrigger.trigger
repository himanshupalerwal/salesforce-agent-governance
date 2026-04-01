/**
 * @description Trigger on AgentGov_Alert__e platform event.
 *              Handles alert notifications (logging, future: email alerts).
 */
trigger AgentGovAlertTrigger on AgentGov_Alert__e (after insert) {
    for (AgentGov_Alert__e alert : Trigger.New) {
        System.debug(LoggingLevel.WARN,
            'AgentGov Alert: ' + alert.Alert_Type__c +
            ' for agent ' + alert.Agent_Name__c +
            ' — ' + alert.Limit_Type__c +
            ' at ' + alert.Usage_Percentage__c + '% usage'
        );
    }
}
