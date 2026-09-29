/**
 * @description Invocable action that reports the resources an agent actually consumed, so
 *              Flows can charge real usage instead of estimates. Bulk-safe: usage for the
 *              same agent across a batch is summed and charged once. Each report is audited
 *              as a Report row, and a report with a negative count is refused.
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
        @InvocableVariable(
            label='Correlation ID'
            description='Optional. Stored on the audit rows so they can be traced, for example {!$Flow.InterviewGuid}. Flow runs batched into one transaction share the first id supplied.'
        )
        public String correlationId;
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
        // Negative usage is always malformed. Ignoring it silently let a Flow believe a
        // correction had been applied; it is now refused, as the REST /report endpoint does.
        Set<Integer> rejected = new Set<Integer>();
        // A deactivated agent may not change its own ledger, as REST /report refuses it.
        Set<Integer> deactivated = new Set<Integer>();
        Set<Id> requestedIds = new Set<Id>();
        for (Request request : requests) {
            if (request.registrationId != null) {
                requestedIds.add(request.registrationId);
            }
        }
        Map<Id, AgentGov_Registration__c> agents = AgentGovSelector.getRegistrationsByIds(requestedIds);
        String correlationId;
        for (Integer i = 0; i < requests.size(); i++) {
            Request request = requests[i];
            if (correlationId == null && String.isNotBlank(request.correlationId)) {
                correlationId = request.correlationId;
            }
            if (request.registrationId == null) {
                continue;
            }
            AgentGov_Registration__c reporting = agents.get(request.registrationId);
            if (reporting != null && reporting.Status__c == AgentGovConstants.STATUS_INACTIVE) {
                deactivated.add(i);
                readOnlyIds.add(request.registrationId);
                continue;
            }
            if (hasNegative(request)) {
                rejected.add(i);
                readOnlyIds.add(request.registrationId);
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
        AgentGovRequestContext.ensureBegun(correlationId);
        Set<Id> reportingIds = new Set<Id>(consumption.keySet());
        Boolean bypassed = !AgentGovSelector.isFrameworkEnabled();
        if (bypassed) {
            consumption.clear();
        }
        // A usage report describes work already counted as an action when it was authorized,
        // so no actions are passed: the session gains the usage but not another action.
        AgentGovBudgetManager.BatchOutcome outcome = AgentGovBudgetManager.consumeBudgets(
            consumption,
            new Map<Id, Integer>()
        );
        // Agents that reported nothing, agents whose report pushed them over budget, and every
        // reporting agent during an emergency bypass are read back so the Flow still receives
        // their current status. The bypass case used to answer "agent not found" instead.
        Set<Id> toRead = new Set<Id>(readOnlyIds);
        if (bypassed) {
            toRead.addAll(reportingIds);
        }
        for (Id registrationId : outcome.failures.keySet()) {
            if (outcome.failures.get(registrationId).getErrorCode() == AgentGovException.ErrorCode.BUDGET_EXCEEDED) {
                toRead.add(registrationId);
            }
        }
        toRead.retainAll(AgentGovSelector.getRegistrationsByIds(toRead).keySet());
        Map<Id, AgentGovBudgetManager.BudgetResult> snapshots = AgentGovBudgetManager.checkBudgets(toRead);

        List<Result> results = new List<Result>();
        List<AgentGov_Action_Event__e> events = new List<AgentGov_Action_Event__e>();
        for (Integer i = 0; i < requests.size(); i++) {
            Request request = requests[i];
            Result result = new Result();
            if (deactivated.contains(i)) {
                AgentGov_Registration__c agent = agents.get(request.registrationId);
                AgentGovBudgetManager.BudgetResult current = snapshots.get(request.registrationId);
                result.budgetStatus = current?.budgetStatus;
                result.allowed = false;
                result.errorMessage = AgentGovConstants.ERR_AGENT_NOT_ACTIVE;
                events.add(
                    AgentGovTriggerHandler.buildEvent(
                        agent.Id,
                        agent.Agent_Name__c,
                        AgentGovConstants.ACTION_REPORT,
                        null,
                        null,
                        AgentGovConstants.ACTION_DENIED,
                        AgentGovConstants.ERR_AGENT_NOT_ACTIVE
                    )
                );
                results.add(result);
                continue;
            }
            if (rejected.contains(i)) {
                AgentGovBudgetManager.BudgetResult current = snapshots.get(request.registrationId);
                result.budgetStatus = current?.budgetStatus;
                result.allowed = false;
                result.errorMessage = AgentGovConstants.ERR_NEGATIVE_USAGE;
                results.add(result);
                continue;
            }
            AgentGov_Registration__c agent = agents.get(request.registrationId);
            if (agent != null && hasUsage(request)) {
                // Audited like REST /report: a charged report is a Success row and one that
                // pushed the agent over its budget is a Denied row.
                AgentGovException failure = outcome.failures.get(request.registrationId);
                events.add(
                    AgentGovTriggerHandler.buildEvent(
                        agent.Id,
                        agent.Agent_Name__c,
                        AgentGovConstants.ACTION_REPORT,
                        null,
                        null,
                        failure == null ? AgentGovConstants.ACTION_SUCCESS : AgentGovConstants.ACTION_DENIED,
                        failure == null ? describeUsage(request) : failure.getMessage()
                    )
                );
            }
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
        AgentGovTriggerHandler.logActions(events);
        return results;
    }

    private static String describeUsage(Request request) {
        return JSON.serialize(
            new Map<String, Object>{
                'apiCalls' => request.apiCallsUsed,
                'soqlQueries' => request.soqlQueriesUsed,
                'dmlOperations' => request.dmlStatementsUsed
            }
        );
    }

    private static Boolean hasUsage(Request request) {
        return (request.apiCallsUsed != null &&
            request.apiCallsUsed > 0) ||
            (request.soqlQueriesUsed != null &&
            request.soqlQueriesUsed > 0) ||
            (request.dmlStatementsUsed != null &&
            request.dmlStatementsUsed > 0);
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
