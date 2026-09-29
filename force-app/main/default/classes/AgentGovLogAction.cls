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
        @InvocableVariable(
            label='Status'
            required=true
            description='Success, Failure, Denied, Throttled. Success and Failure also count toward the agent\'s circuit breaker.'
        )
        public String status;
        @InvocableVariable(label='Details')
        public String details;
        @InvocableVariable(
            label='Execution Time (ms)'
            description='Optional. How long the logged action took, when the Flow measured it.'
        )
        public Integer executionTimeMs;
        @InvocableVariable(
            label='Correlation ID'
            description='Optional. Stored on the audit rows so they can be traced, for example {!$Flow.InterviewGuid}. Flow runs batched into one transaction share the first id supplied.'
        )
        public String correlationId;
    }

    /** @description Outcome for one request. */
    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    /**
     * @description Records each action. A Success or Failure status is also reported to the
     *              agent's circuit breaker, so a Flow that logs its own failures trips the
     *              breaker as REST and proxy agents do. No outcome is recorded for a deactivated
     *              agent, or while governance is switched off.
     * @param requests Requests in Flow order
     * @return Results in the same order
     */
    @InvocableMethod(label='Log Agent Action' description='Logs an action performed by an agent' category='AgentGov')
    public static List<Result> logAction(List<Request> requests) {
        List<Result> results = new List<Result>();
        Set<Id> registrationIds = new Set<Id>();
        String correlationId;
        for (Request request : requests) {
            if (request.registrationId != null) {
                registrationIds.add(request.registrationId);
            }
            if (correlationId == null && String.isNotBlank(request.correlationId)) {
                correlationId = request.correlationId;
            }
        }
        AgentGovRequestContext.ensureBegun(correlationId);
        Map<Id, AgentGov_Registration__c> registrations = AgentGovSelector.getRegistrationsByIds(registrationIds);
        Boolean governed = AgentGovSelector.isFrameworkEnabled();

        List<AgentGov_Action_Event__e> events = new List<AgentGov_Action_Event__e>();
        Map<Id, Boolean> outcomes = new Map<Id, Boolean>();
        for (Request request : requests) {
            Result result = new Result();
            if (request.registrationId == null) {
                result.success = false;
                result.errorMessage = AgentGovConstants.ERR_NULL_AGENT_ID;
            } else {
                AgentGov_Registration__c registration = registrations.get(request.registrationId);
                AgentGov_Action_Event__e event = AgentGovTriggerHandler.buildEvent(
                    request.registrationId,
                    registration != null ? registration.Agent_Name__c : AgentGovConstants.UNKNOWN_AGENT_NAME,
                    request.actionType,
                    request.objectName,
                    request.recordId,
                    request.status,
                    request.details
                );
                // The Flow's own measurement of the action it is logging, when it has one,
                // says more than the time this call took.
                if (request.executionTimeMs != null && request.executionTimeMs >= 0) {
                    event.Execution_Time_Ms__c = request.executionTimeMs;
                }
                events.add(event);
                result.success = true;
                if (governed && registration != null && registration.Status__c != AgentGovConstants.STATUS_INACTIVE) {
                    noteOutcome(outcomes, registration.Id, request.status);
                }
            }
            results.add(result);
        }
        AgentGovTriggerHandler.logActions(events);
        AgentGovCircuitBreaker.recordOutcomes(outcomes);
        return results;
    }

    // One outcome per agent per batch, as the other entry points record it: a failure anywhere
    // in the batch counts as a failure, and only Success and Failure count at all.
    private static void noteOutcome(Map<Id, Boolean> outcomes, Id registrationId, String status) {
        if (status == AgentGovConstants.ACTION_FAILURE) {
            outcomes.put(registrationId, false);
        } else if (status == AgentGovConstants.ACTION_SUCCESS && !outcomes.containsKey(registrationId)) {
            outcomes.put(registrationId, true);
        }
    }
}
