/**
 * @description Invocable action that reports actual resource usage for an agent.
 *              Used in Flows to report how many operations were actually consumed,
 *              enabling accurate budget tracking instead of self-reported estimates.
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovReportUsage {

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

    public class Result {
        @InvocableVariable(label='Budget Status')
        public String budgetStatus;
        @InvocableVariable(label='API Calls Remaining')
        public Decimal apiCallsRemaining;
        @InvocableVariable(label='SOQL Queries Remaining')
        public Decimal soqlQueriesRemaining;
        @InvocableVariable(label='DML Operations Remaining')
        public Decimal dmlOperationsRemaining;
    }

    @InvocableMethod(label='Report Agent Usage' description='Reports actual resource usage for budget tracking' category='AgentGov')
    public static List<Result> reportUsage(List<Request> requests) {
        List<Result> results = new List<Result>();

        for (Request req : requests) {
            Map<String, Integer> consumption = new Map<String, Integer>();
            if (req.apiCallsUsed != null && req.apiCallsUsed > 0) {
                consumption.put(AgentGovConstants.LIMIT_API_CALLS, req.apiCallsUsed);
            }
            if (req.soqlQueriesUsed != null && req.soqlQueriesUsed > 0) {
                consumption.put(AgentGovConstants.LIMIT_SOQL_QUERIES, req.soqlQueriesUsed);
            }
            if (req.dmlStatementsUsed != null && req.dmlStatementsUsed > 0) {
                consumption.put(AgentGovConstants.LIMIT_DML_OPERATIONS, req.dmlStatementsUsed);
            }

            AgentGovBudgetManager.BudgetResult budgetResult;
            if (!consumption.isEmpty()) {
                budgetResult = AgentGovBudgetManager.consumeBudget(req.registrationId, consumption);
            } else {
                budgetResult = AgentGovBudgetManager.checkBudget(req.registrationId);
            }

            Result res = new Result();
            res.budgetStatus = budgetResult.budgetStatus;
            res.apiCallsRemaining = budgetResult.apiCallsRemaining;
            res.soqlQueriesRemaining = budgetResult.soqlQueriesRemaining;
            res.dmlOperationsRemaining = budgetResult.dmlOperationsRemaining;
            results.add(res);
        }

        return results;
    }
}
