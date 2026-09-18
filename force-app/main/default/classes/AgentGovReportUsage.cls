/**
 * @description Invocable action that reports the resources an agent actually consumed, so
 *              Flows can charge real usage instead of estimates. Bulk-safe: usage for the
 *              same agent across a batch is summed and charged once.
 *
 *              Security posture: with sharing. Budget writes run in system mode through
 *              AgentGovBudgetManager.
 */
public with sharing class AgentGovReportUsage {
    /** @description Usage for one agent. */
    public class Request {
        @InvocableVariable(label='Agent Registration ID' required=true)
        public Id registrationId;
        @InvocableVariable(label='API Calls Used' required=false)
        public Integer apiCallsUsed;
        @InvocableVariable(label='SOQL Queries Used' required=false)
        public Integer soqlQueriesUsed;
        @InvocableVariable(label='DML Statements Used' required=false)
        public Integer dmlStatementsUsed;
    }

    /** @description Budget after the report. */
    public class Result {
        @InvocableVariable(label='Budget Status')
        public String budgetStatus;
        @InvocableVariable(label='Budget Allowed')
        public Boolean allowed;
        @InvocableVariable(label='API Calls Remaining')
        public Decimal apiCallsRemaining;
        @InvocableVariable(label='SOQL Queries Remaining')
        public Decimal soqlQueriesRemaining;
        @InvocableVariable(label='DML Operations Remaining')
        public Decimal dmlOperationsRemaining;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    /**
     * @description Charges the reported usage to each agent's budget.
     * @param requests Requests in Flow order
     * @return Results in the same order
     */
    @InvocableMethod(
        label='Report Agent Usage'
        description='Reports actual resource usage for budget tracking'
        category='AgentGov'
    )
    public static List<Result> reportUsage(List<Request> requests) {
        Map<Id, Map<String, Integer>> consumption = new Map<Id, Map<String, Integer>>();
        Set<Id> readOnlyIds = new Set<Id>();
        for (Request request : requests) {
            if (request.registrationId == null) {
                continue;
            }
            Map<String, Integer> usage = new Map<String, Integer>();
            addUsage(usage, AgentGovConstants.LIMIT_API_CALLS, request.apiCallsUsed);
            addUsage(usage, AgentGovConstants.LIMIT_SOQL_QUERIES, request.soqlQueriesUsed);
            addUsage(usage, AgentGovConstants.LIMIT_DML_OPERATIONS, request.dmlStatementsUsed);
            if (usage.isEmpty()) {
                readOnlyIds.add(request.registrationId);
                continue;
            }
            if (!consumption.containsKey(request.registrationId)) {
                consumption.put(request.registrationId, new Map<String, Integer>());
            }
            Map<String, Integer> total = consumption.get(request.registrationId);
            for (String limitType : usage.keySet()) {
                total.put(limitType, (total.containsKey(limitType) ? total.get(limitType) : 0) + usage.get(limitType));
            }
        }

        // Is_Enabled__c suspends enforcement everywhere, reporting included. Charging during
        // an emergency bypass could deny the agent with BUDGET_EXCEEDED, which is the outcome
        // the switch exists to prevent. The usage is still reported back to the Flow.
        if (!AgentGovSelector.isFrameworkEnabled()) {
            consumption.clear();
        }
        AgentGovBudgetManager.BatchOutcome outcome = AgentGovBudgetManager.consumeBudgets(consumption);
        // Agents that reported nothing, and agents whose report pushed them over budget,
        // are read back so the Flow still receives their current status.
        Set<Id> toRead = new Set<Id>(readOnlyIds);
        for (Id registrationId : outcome.failures.keySet()) {
            if (outcome.failures.get(registrationId).getErrorCode() == AgentGovException.ErrorCode.BUDGET_EXCEEDED) {
                toRead.add(registrationId);
            }
        }
        toRead.retainAll(AgentGovSelector.getRegistrationsByIds(toRead).keySet());
        Map<Id, AgentGovBudgetManager.BudgetResult> snapshots = AgentGovBudgetManager.checkBudgets(toRead);

        List<Result> results = new List<Result>();
        for (Request request : requests) {
            Result result = new Result();
            AgentGovBudgetManager.BudgetResult budget = outcome.results.containsKey(request.registrationId)
                ? outcome.results.get(request.registrationId)
                : snapshots.get(request.registrationId);
            if (budget != null) {
                result.budgetStatus = budget.budgetStatus;
                result.allowed = budget.allowed;
                result.apiCallsRemaining = budget.apiCallsRemaining;
                result.soqlQueriesRemaining = budget.soqlQueriesRemaining;
                result.dmlOperationsRemaining = budget.dmlOperationsRemaining;
            }
            if (outcome.failures.containsKey(request.registrationId)) {
                result.errorMessage = outcome.failures.get(request.registrationId).getMessage();
                result.allowed = false;
            } else if (budget == null) {
                result.allowed = false;
                result.errorMessage = request.registrationId == null
                    ? AgentGovConstants.ERR_NULL_AGENT_ID
                    : AgentGovConstants.ERR_AGENT_NOT_FOUND;
            }
            results.add(result);
        }
        return results;
    }

    private static Boolean hasNegative(Request request) {
        return (request.apiCallsUsed != null &&
            request.apiCallsUsed < 0) ||
            (request.soqlQueriesUsed != null &&
            request.soqlQueriesUsed < 0) ||
            (request.dmlStatementsUsed != null &&
            request.dmlStatementsUsed < 0);
    }

    private static void addUsage(Map<String, Integer> usage, String limitType, Integer amount) {
        if (amount != null && amount > 0) {
            usage.put(limitType, amount);
        }
    }
}
