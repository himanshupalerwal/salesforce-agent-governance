/**
 * @description Invocable action that registers an agent action and consumes budget in one call.
 *              This is the primary entry point for Flow-based agents.
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovRegisterAction {

    public class Request {
        @InvocableVariable(label='Agent Registration ID' required=true)
        public Id registrationId;
        @InvocableVariable(label='Action Type' required=true description='Query, Create, Update, Delete, Upsert, API_Call, Flow_Trigger')
        public String actionType;
        @InvocableVariable(label='Object Name' required=true)
        public String objectName;
        @InvocableVariable(label='Record ID')
        public String recordId;
    }

    public class Result {
        @InvocableVariable(label='Authorized')
        public Boolean authorized;
        @InvocableVariable(label='Budget Status')
        public String budgetStatus;
        @InvocableVariable(label='Denial Reason')
        public String denialReason;
    }

    @InvocableMethod(label='Register Agent Action' description='Checks policy, consumes budget, and logs action in one call' category='AgentGov')
    public static List<Result> registerAction(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result result = new Result();
            try {
                // Skip governance if framework disabled
                if (!AgentGovSelector.isFrameworkEnabled()) {
                    result.authorized = true;
                    result.budgetStatus = 'Framework disabled - bypassed';
                    results.add(result);
                    continue;
                }

                // 1. Check circuit breaker
                if (!AgentGovCircuitBreaker.allowRequest(req.registrationId)) {
                    result.authorized = false;
                    result.denialReason = AgentGovConstants.ERR_CIRCUIT_BREAKER_OPEN;
                    AgentGovTriggerHandler.logAction(req.registrationId, req.actionType, req.objectName, req.recordId, AgentGovConstants.ACTION_DENIED, result.denialReason);
                    results.add(result);
                    continue;
                }

                // 2. Check policy
                AgentGovPolicyEngine.PolicyResult policyResult = AgentGovPolicyEngine.evaluatePolicy(
                    req.registrationId, req.objectName, req.actionType
                );
                if (!policyResult.allowed) {
                    result.authorized = false;
                    result.denialReason = policyResult.denialReason;
                    AgentGovTriggerHandler.logAction(req.registrationId, req.actionType, req.objectName, req.recordId, AgentGovConstants.ACTION_DENIED, policyResult.denialReason);
                    results.add(result);
                    continue;
                }

                // 3. Check and consume budget
                String limitType = req.actionType == AgentGovConstants.ACTION_QUERY
                    ? AgentGovConstants.LIMIT_SOQL_QUERIES
                    : (req.actionType == AgentGovConstants.ACTION_API_CALL
                        ? AgentGovConstants.LIMIT_API_CALLS
                        : AgentGovConstants.LIMIT_DML_OPERATIONS);

                AgentGovBudgetManager.BudgetResult budgetResult = AgentGovBudgetManager.consumeBudget(
                    req.registrationId, limitType, 1
                );
                result.authorized = true;
                result.budgetStatus = budgetResult.budgetStatus;

                // 4. Log success
                AgentGovTriggerHandler.logAction(req.registrationId, req.actionType, req.objectName, req.recordId, AgentGovConstants.ACTION_SUCCESS, null);

                // Record success for circuit breaker
                AgentGovCircuitBreaker.recordSuccess(req.registrationId);

            } catch (AgentGovException e) {
                result.authorized = false;
                result.denialReason = e.getMessage();
                if (e.getErrorCode() != AgentGovException.ErrorCode.BUDGET_EXCEEDED
                    && e.getErrorCode() != AgentGovException.ErrorCode.BUDGET_THROTTLED) {
                    AgentGovCircuitBreaker.recordFailure(req.registrationId);
                }
            } catch (Exception e) {
                result.authorized = false;
                result.denialReason = e.getMessage();
            }
            results.add(result);
        }
        return results;
    }
}
