/**
 * @description Invocable action that reports an agent's status and circuit breaker state.
 *              Bulk-safe: all requests in a batch are served by one registration read.
 *
 *              Security posture: with sharing. Registration reads run in system mode
 *              through AgentGovSelector.
 */
public with sharing class AgentGovGetStatus {
    /** @description Request for one agent. */
    public class Request {
        @InvocableVariable(label='Agent Registration ID' required=true)
        public Id registrationId;
    }

    /** @description Health snapshot for one agent. */
    public class Result {
        @InvocableVariable(label='Agent Name')
        public String agentName;
        @InvocableVariable(label='Agent Status')
        public String agentStatus;
        @InvocableVariable(label='Circuit Breaker State')
        public String circuitBreakerState;
        @InvocableVariable(label='Is Healthy')
        public Boolean isHealthy;
        @InvocableVariable(label='Failure Count')
        public Decimal failureCount;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    /**
     * @description Reads the status of each requested agent.
     * @param requests Requests in Flow order
     * @return Results in the same order
     */
    @InvocableMethod(
        label='Get Agent Status'
        description='Gets the current health status of an agent'
        category='AgentGov'
    )
    public static List<Result> getStatus(List<Request> requests) {
        List<Result> results = new List<Result>();
        Set<Id> registrationIds = new Set<Id>();
        for (Request request : requests) {
            if (request.registrationId != null) {
                registrationIds.add(request.registrationId);
            }
        }
        Map<Id, AgentGov_Registration__c> registrations = AgentGovSelector.getRegistrationsByIds(registrationIds);

        for (Request request : requests) {
            Result result = new Result();
            AgentGov_Registration__c registration = registrations.get(request.registrationId);
            if (registration == null) {
                result.isHealthy = false;
                result.errorMessage = AgentGovConstants.ERR_AGENT_NOT_FOUND;
            } else {
                result.agentName = registration.Agent_Name__c;
                result.agentStatus = registration.Status__c;
                result.circuitBreakerState = registration.Circuit_Breaker_State__c;
                result.failureCount = registration.Failure_Count__c;
                result.isHealthy =
                    registration.Status__c == AgentGovConstants.STATUS_ACTIVE &&
                    registration.Circuit_Breaker_State__c == AgentGovConstants.CB_CLOSED;
            }
            results.add(result);
        }
        return results;
    }
}
