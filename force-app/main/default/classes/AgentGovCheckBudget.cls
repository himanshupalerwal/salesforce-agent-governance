/**
 * @description Invocable action to check agent budget from Flows.
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovCheckBudget {

    public class Request {
        @InvocableVariable(label='Agent Registration ID' required=true)
        public Id registrationId;
    }

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

    @InvocableMethod(label='Check Agent Budget' description='Checks if an agent has governor budget remaining' category='AgentGov')
    public static List<Result> checkBudget(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result result = new Result();
            try {
                AgentGovBudgetManager.BudgetResult budget = AgentGovBudgetManager.checkBudget(req.registrationId);
                result.hasBudget = budget.allowed;
                result.budgetStatus = budget.budgetStatus;
                result.apiCallsRemaining = budget.apiCallsRemaining;
                result.soqlQueriesRemaining = budget.soqlQueriesRemaining;
                result.dmlOperationsRemaining = budget.dmlOperationsRemaining;
            } catch (Exception e) {
                result.hasBudget = false;
                result.errorMessage = e.getMessage();
            }
            results.add(result);
        }
        return results;
    }
}
