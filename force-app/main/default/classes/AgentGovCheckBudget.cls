/**
 * @description Invocable action that reads an agent's budget without consuming any of it.
 *              Bulk-safe: all requests in a batch are served by one budget read.
 *
 *              Security posture: with sharing. Budget reads run in system mode through
 *              AgentGovBudgetManager.
 */
public with sharing class AgentGovCheckBudget {
    /** @description Request for one agent. */
    public class Request {
        @InvocableVariable(label='Agent Registration ID' required=true)
        public Id registrationId;
    }

    /** @description Budget snapshot for one agent. */
    public class Result {
        @InvocableVariable(label='Has Budget')
        public Boolean hasBudget;
        @InvocableVariable(label='Budget Status')
        public String budgetStatus;
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
     * @description Reads the budget for each requested agent.
     * @param requests Requests in Flow order
     * @return Results in the same order
     */
    @InvocableMethod(
        label='Check Agent Budget'
        description='Checks whether an agent has governor budget remaining'
        category='AgentGov'
    )
    public static List<Result> checkBudget(List<Request> requests) {
        List<Result> results = new List<Result>();
        Set<Id> registrationIds = new Set<Id>();
        for (Request request : requests) {
            if (request.registrationId != null) {
                registrationIds.add(request.registrationId);
            }
        }
        Set<Id> knownIds = AgentGovSelector.getRegistrationsByIds(registrationIds).keySet();
        Map<Id, AgentGovBudgetManager.BudgetResult> budgets = AgentGovBudgetManager.checkBudgets(knownIds);

        for (Request request : requests) {
            Result result = new Result();
            AgentGovBudgetManager.BudgetResult budget = budgets.get(request.registrationId);
            if (budget == null) {
                result.hasBudget = false;
                result.errorMessage = request.registrationId == null
                    ? AgentGovConstants.ERR_NULL_AGENT_ID
                    : AgentGovConstants.ERR_AGENT_NOT_FOUND;
            } else {
                result.hasBudget = budget.allowed;
                result.budgetStatus = budget.budgetStatus;
                result.apiCallsRemaining = budget.apiCallsRemaining;
                result.soqlQueriesRemaining = budget.soqlQueriesRemaining;
                result.dmlOperationsRemaining = budget.dmlOperationsRemaining;
            }
            results.add(result);
        }
        return results;
    }
}
