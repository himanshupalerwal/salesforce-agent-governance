/**
 * @description Invocable action to get agent health status from Flows.
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovGetStatus {

    public class Request {
        @InvocableVariable(label='Agent Registration ID' required=true)
        public Id registrationId;
    }

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

    @InvocableMethod(label='Get Agent Status' description='Gets the current health status of an agent' category='AgentGov')
    public static List<Result> getStatus(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result result = new Result();
            try {
                AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById(req.registrationId);
                if (reg == null) {
                    result.errorMessage = AgentGovConstants.ERR_AGENT_NOT_FOUND;
                    result.isHealthy = false;
                } else {
                    result.agentName = reg.Agent_Name__c;
                    result.agentStatus = reg.Status__c;
                    result.circuitBreakerState = reg.Circuit_Breaker_State__c;
                    result.failureCount = reg.Failure_Count__c;
                    result.isHealthy = reg.Status__c == AgentGovConstants.STATUS_ACTIVE
                        && reg.Circuit_Breaker_State__c == AgentGovConstants.CB_CLOSED;
                }
            } catch (Exception e) {
                result.isHealthy = false;
                result.errorMessage = e.getMessage();
            }
            results.add(result);
        }
        return results;
    }
}
