/**
 * @description Invocable action that records an agent action in the audit log.
 *              Bulk-safe: all requests in a batch are published with one event publish.
 *
 *              Security posture: with sharing. Audit writes run in system mode through
 *              AgentGovTriggerHandler.
 */
public with sharing class AgentGovLogAction {
    /** @description One action to record. */
    public class Request {
        @InvocableVariable(label='Agent Registration ID' required=true)
        public Id registrationId;
        @InvocableVariable(
            label='Action Type'
            required=true
            description='Query, Create, Update, Delete, Upsert, API_Call, Flow_Trigger'
        )
        public String actionType;
        @InvocableVariable(label='Object Name')
        public String objectName;
        @InvocableVariable(label='Record ID')
        public String recordId;
        @InvocableVariable(label='Status' required=true description='Success, Failure, Denied, Throttled')
        public String status;
        @InvocableVariable(label='Details')
        public String details;
    }

    /** @description Outcome for one request. */
    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    /**
     * @description Records each action.
     * @param requests Requests in Flow order
     * @return Results in the same order
     */
    @InvocableMethod(label='Log Agent Action' description='Logs an action performed by an agent' category='AgentGov')
    public static List<Result> logAction(List<Request> requests) {
        List<Result> results = new List<Result>();
        Set<Id> registrationIds = new Set<Id>();
        for (Request request : requests) {
            if (request.registrationId != null) {
                registrationIds.add(request.registrationId);
            }
        }
        Map<Id, AgentGov_Registration__c> registrations = AgentGovSelector.getRegistrationsByIds(registrationIds);

        List<AgentGov_Action_Event__e> events = new List<AgentGov_Action_Event__e>();
        for (Request request : requests) {
            Result result = new Result();
            if (request.registrationId == null) {
                result.success = false;
                result.errorMessage = AgentGovConstants.ERR_NULL_AGENT_ID;
            } else {
                AgentGov_Registration__c registration = registrations.get(request.registrationId);
                events.add(
                    AgentGovTriggerHandler.buildEvent(
                        request.registrationId,
                        registration != null ? registration.Agent_Name__c : AgentGovConstants.UNKNOWN_AGENT_NAME,
                        request.actionType,
                        request.objectName,
                        request.recordId,
                        request.status,
                        request.details
                    )
                );
                result.success = true;
            }
            results.add(result);
        }
        AgentGovTriggerHandler.logActions(events);
        return results;
    }
}
