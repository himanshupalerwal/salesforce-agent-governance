/**
 * @description Allocates, tracks, and enforces daily governor budgets per agent.
 *
 *              A budget row exists per agent per day and is created on first use. Its status
 *              is the most severe status across the three limit types, evaluated against the
 *              thresholds in AgentGov_Limit_Config__mdt: Normal, Warning, Throttled, Blocked,
 *              or Exhausted. Blocked and Exhausted budgets deny every operation until the
 *              daily reset or a credit brings usage back under the block threshold.
 *
 *              Consumption is always persisted before a denial is raised, so the ledger
 *              records attempts that pushed an agent over its limit. Bulk callers use
 *              consumeBudgets, which locks every affected budget row in one query and
 *              writes them back in one statement.
 *
 *              Security posture: inherited sharing. Reads go through AgentGovSelector and
 *              writes through AgentGovDml, both of which run in system mode so that
 *              bookkeeping succeeds regardless of the calling user's access.
 */
public inherited sharing class AgentGovBudgetManager {
    private static final List<String> LIMIT_TYPES = new List<String>{
        AgentGovConstants.LIMIT_API_CALLS,
        AgentGovConstants.LIMIT_SOQL_QUERIES,
        AgentGovConstants.LIMIT_DML_OPERATIONS
    };

    /**
     * @description Largest value AgentGov_Alert__e.Usage_Percentage__c can hold, which is
     *              declared as Number(5,2). Reported usage is clamped to it.
     */
    private static final Decimal MAX_ALERT_PERCENT = 999.99;

    /** @description Snapshot of an agent's budget after a check or consumption. */
    public class BudgetResult {
        @AuraEnabled
        public Boolean allowed;
        @AuraEnabled
        public String budgetStatus;
        @AuraEnabled
        public Decimal apiCallsRemaining;
        @AuraEnabled
        public Decimal soqlQueriesRemaining;
        @AuraEnabled
        public Decimal dmlOperationsRemaining;
        @AuraEnabled
        public Decimal apiUsagePercent;
        @AuraEnabled
        public Decimal soqlUsagePercent;
        @AuraEnabled
        public Decimal dmlUsagePercent;
    }

    /** @description Threshold set for one limit type, as percentages of the daily allocation. */
    public class Thresholds {
        public Decimal warning;
        public Decimal throttle;
        public Decimal block;
    }

    /**
     * @description Outcome of a bulk consumption. Every requested agent appears in exactly
     *              one of the two maps: results for agents that were charged and remain
     *              allowed, failures for agents whose request must be denied.
     */
    public class BatchOutcome {
        public Map<Id, BudgetResult> results = new Map<Id, BudgetResult>();
        public Map<Id, AgentGovException> failures = new Map<Id, AgentGovException>();
    }

    /** Evaluation of one budget row across all limit types. */
    private class Evaluation {
        private String status = AgentGovConstants.BUDGET_NORMAL;
        private String worstLimitType;
        private Decimal worstPercent = 0;
        private Decimal worstConsumed = 0;
        private Decimal worstAllocated = 0;
    }

    // Tests cannot insert custom metadata, so they inject thresholds here.
    @TestVisible
    private static Map<String, Thresholds> thresholdOverrides = new Map<String, Thresholds>();

    /**
     * @description Reads an agent's budget without consuming anything, creating today's row if needed.
     * @param registrationId The agent registration Id
     * @return The current budget snapshot
     * @throws AgentGovException INVALID_INPUT for a null Id, AGENT_NOT_FOUND for an unknown agent
     */
    public static BudgetResult checkBudget(Id registrationId) {
        requireId(registrationId);
        return checkBudgets(new Set<Id>{ registrationId }).get(registrationId);
    }

    /**
     * @description Reads budgets for several agents in one query, creating today's rows if needed.
     * @param registrationIds Agent registration Ids
     * @return Map of registration Id to budget snapshot
     * @throws AgentGovException AGENT_NOT_FOUND when any Id has no registration
     */
    public static Map<Id, BudgetResult> checkBudgets(Set<Id> registrationIds) {
        Map<Id, BudgetResult> results = new Map<Id, BudgetResult>();
        Map<Id, AgentGov_Budget__c> budgets = getOrCreateTodaysBudgets(registrationIds, false, null);
        for (Id registrationId : budgets.keySet()) {
            results.put(registrationId, buildBudgetResult(budgets.get(registrationId)));
        }
        return results;
    }

    /**
     * @description Consumes budget of one limit type for an agent.
     * @param registrationId The agent registration Id
     * @param limitType One of the AgentGovConstants.LIMIT_* values
     * @param amount Units to consume
     * @return The budget snapshot after consumption
     * @throws AgentGovException BUDGET_EXCEEDED when the budget is Blocked or Exhausted after consumption
     */
    public static BudgetResult consumeBudget(Id registrationId, String limitType, Integer amount) {
        requireId(registrationId);
        requireLimitType(limitType);
        return consumeBudget(registrationId, new Map<String, Integer>{ limitType => amount });
    }

    /**
     * @description Consumes several limit types for an agent in a single budget update.
     * @param registrationId The agent registration Id
     * @param consumption Map of limit type to units consumed
     * @return The budget snapshot after consumption
     * @throws AgentGovException BUDGET_EXCEEDED when the budget is Blocked or Exhausted after consumption
     */
    public static BudgetResult consumeBudget(Id registrationId, Map<String, Integer> consumption) {
        requireId(registrationId);
        if (consumption == null || consumption.isEmpty()) {
            return checkBudget(registrationId);
        }
        BatchOutcome outcome = consumeBudgets(new Map<Id, Map<String, Integer>>{ registrationId => consumption });
        if (outcome.failures.containsKey(registrationId)) {
            throw outcome.failures.get(registrationId);
        }
        return outcome.results.get(registrationId);
    }

    /**
     * @description Consumes budget for many agents at once: one locking query, one update,
     *              one alert publish. Never throws for a single agent's denial; denials are
     *              returned in the outcome so bulk callers can report per request.
     * @param consumptionByAgent Map of registration Id to its consumption by limit type
     * @return Per-agent results and failures
     */
    public static BatchOutcome consumeBudgets(Map<Id, Map<String, Integer>> consumptionByAgent) {
        BatchOutcome outcome = new BatchOutcome();
        if (consumptionByAgent == null || consumptionByAgent.isEmpty()) {
            return outcome;
        }

        Set<Id> registrationIds = new Set<Id>();
        for (Id registrationId : consumptionByAgent.keySet()) {
            if (registrationId == null) {
                continue;
            }
            AgentGovException invalid = validateConsumption(consumptionByAgent.get(registrationId));
            if (invalid != null) {
                outcome.failures.put(registrationId, invalid);
            } else {
                registrationIds.add(registrationId);
            }
        }

        Map<Id, AgentGov_Budget__c> budgets = getOrCreateTodaysBudgets(registrationIds, true, outcome.failures);
        List<AgentGov_Budget__c> toUpdate = new List<AgentGov_Budget__c>();
        List<AgentGov_Alert__e> alerts = new List<AgentGov_Alert__e>();

        // Seed the registration cache in one query. Alerts need the agent name, and building
        // them one at a time would issue a query per escalating agent from inside the loop
        // below, which a large Flow batch turns into a governor-limit failure.
        Map<Id, AgentGov_Registration__c> agents = AgentGovSelector.getRegistrationsByIds(budgets.keySet());

        for (Id registrationId : budgets.keySet()) {
            AgentGov_Budget__c budget = budgets.get(registrationId);
            String previousStatus = budget.Budget_Status__c == null
                ? AgentGovConstants.BUDGET_NORMAL
                : budget.Budget_Status__c;

            for (String limitType : consumptionByAgent.get(registrationId).keySet()) {
                Integer amount = consumptionByAgent.get(registrationId).get(limitType);
                if (amount == null || amount <= 0) {
                    continue;
                }
                setConsumed(budget, limitType, getConsumed(budget, limitType) + amount);
            }

            Evaluation evaluation = evaluate(budget);
            budget.Budget_Status__c = evaluation.status;
            toUpdate.add(budget);

            if (rank(evaluation.status) > rank(previousStatus)) {
                alerts.add(buildAlert(registrationId, agents.get(registrationId), evaluation));
            }
            if (isAllowed(evaluation.status)) {
                outcome.results.put(registrationId, buildBudgetResult(budget));
            } else {
                outcome.failures.put(
                    registrationId,
                    new AgentGovException(
                        AgentGovException.ErrorCode.BUDGET_EXCEEDED,
                        AgentGovConstants.ERR_BUDGET_EXCEEDED + evaluation.worstLimitType
                    )
                );
            }
        }

        // The rows are written before any denial is surfaced so the ledger keeps the
        // consumption that crossed the line, not just the consumption before it.
        AgentGovDml.assertAllSucceeded(AgentGovDml.updateRecords(toUpdate, false), 'Budget update');
        AgentGovTriggerHandler.publishAlerts(alerts);
        updateSessionCounters(consumptionByAgent, budgets.keySet());
        return outcome;
    }

    /**
     * @description Credits consumption back to a budget, for reconciliation when an agent
     *              used less than it pre-authorized. The status is re-evaluated from the
     *              corrected usage, so a Blocked budget can return to a lower status.
     * @param registrationId The agent registration Id
     * @param limitType One of the AgentGovConstants.LIMIT_* values
     * @param amount Units to credit back
     * @return The budget snapshot after the credit
     */
    public static BudgetResult creditBudget(Id registrationId, String limitType, Integer amount) {
        requireId(registrationId);
        requireLimitType(limitType);
        AgentGov_Budget__c budget = getOrCreateTodaysBudgets(new Set<Id>{ registrationId }, true, null)
            .get(registrationId);
        Decimal credited = amount == null || amount < 0 ? 0 : amount;
        setConsumed(budget, limitType, Math.max(0, getConsumed(budget, limitType) - credited));
        budget.Budget_Status__c = evaluate(budget).status;
        AgentGovDml.updateRecord(budget);
        return buildBudgetResult(budget);
    }

    /**
     * @description Alias for checkBudget kept for API compatibility.
     * @param registrationId The agent registration Id
     * @return The current budget snapshot
     */
    public static BudgetResult getRemainingBudget(Id registrationId) {
        return checkBudget(registrationId);
    }

    /**
     * @description Creates today's budget for an agent from its configured daily allocations.
     *              Safe to call when the row already exists: the existing row is returned.
     * @param registrationId The agent registration Id
     * @return Today's budget row
     * @throws AgentGovException AGENT_NOT_FOUND when the registration does not exist
     */
    public static AgentGov_Budget__c createDailyBudget(Id registrationId) {
        requireId(registrationId);
        AgentGov_Registration__c registration = AgentGovSelector.getRegistrationById(registrationId);
        if (registration == null) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.AGENT_NOT_FOUND,
                AgentGovConstants.ERR_AGENT_NOT_FOUND
            );
        }
        AgentGov_Budget__c budget = newBudgetFor(registration, Date.today());
        Database.SaveResult result = AgentGovDml.insertRecords(new List<SObject>{ budget }, false)[0];
        if (result.isSuccess()) {
            return budget;
        }
        if (AgentGovDml.isDuplicateValueFailure(result)) {
            return AgentGovSelector.getTodaysBudget(registrationId);
        }
        throw new AgentGovException(
            AgentGovException.ErrorCode.INTERNAL_ERROR,
            'Budget creation failed: ' + AgentGovDml.describeErrors(result.getErrors())
        );
    }

    /**
     * @description Creates today's budget for every active agent. Called by the daily reset
     *              job; agents that already have a row for today are left untouched.
     * @throws AgentGovException INTERNAL_ERROR when a row fails for any reason other than already existing
     */
    public static void resetDailyBudgets() {
        List<AgentGov_Budget__c> newBudgets = new List<AgentGov_Budget__c>();
        Date today = Date.today();
        for (AgentGov_Registration__c registration : AgentGovSelector.getActiveRegistrations()) {
            newBudgets.add(newBudgetFor(registration, today));
        }
        for (Database.SaveResult result : AgentGovDml.insertRecords(newBudgets, false)) {
            if (!result.isSuccess() && !AgentGovDml.isDuplicateValueFailure(result)) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.INTERNAL_ERROR,
                    'Daily budget reset failed: ' + AgentGovDml.describeErrors(result.getErrors())
                );
            }
        }
    }

    /**
     * @description Builds the unique key that prevents two budget rows for the same agent and day.
     * @param registrationId The agent registration Id
     * @param budgetDate The budget date
     * @return The key stored in Budget_Key__c
     */
    public static String buildBudgetKey(Id registrationId, Date budgetDate) {
        return String.valueOf(registrationId) + '_' + String.valueOf(budgetDate);
    }

    /**
     * @description Resolves a usage percentage to a budget status.
     * @param usagePercent Consumed as a percentage of allocated
     * @param thresholds The thresholds to apply
     * @return One of the AgentGovConstants.BUDGET_* statuses
     */
    public static String resolveStatus(Decimal usagePercent, Thresholds thresholds) {
        if (usagePercent >= 100) {
            return AgentGovConstants.BUDGET_EXHAUSTED;
        }
        if (usagePercent >= thresholds.block) {
            return AgentGovConstants.BUDGET_BLOCKED;
        }
        if (usagePercent >= thresholds.throttle) {
            return AgentGovConstants.BUDGET_THROTTLED;
        }
        if (usagePercent >= thresholds.warning) {
            return AgentGovConstants.BUDGET_WARNING;
        }
        return AgentGovConstants.BUDGET_NORMAL;
    }

    /**
     * @description Returns the thresholds for a limit type from custom metadata, falling back
     *              to the framework defaults for anything not configured.
     * @param limitType One of the AgentGovConstants.LIMIT_* values
     * @return The thresholds to apply
     */
    public static Thresholds thresholdsFor(String limitType) {
        if (thresholdOverrides.containsKey(limitType)) {
            return thresholdOverrides.get(limitType);
        }
        AgentGov_Limit_Config__mdt config = AgentGovSelector.getLimitConfigByType(limitType);
        Thresholds thresholds = new Thresholds();
        thresholds.warning = config != null &&
            config.Warning_Threshold__c != null
            ? config.Warning_Threshold__c
            : AgentGovConstants.DEFAULT_WARNING_THRESHOLD;
        thresholds.throttle = config != null &&
            config.Throttle_Threshold__c != null
            ? config.Throttle_Threshold__c
            : AgentGovConstants.DEFAULT_THROTTLE_THRESHOLD;
        thresholds.block = config != null &&
            config.Block_Threshold__c != null
            ? config.Block_Threshold__c
            : AgentGovConstants.DEFAULT_BLOCK_THRESHOLD;
        return thresholds;
    }

    /**
     * @description Resolves the daily allocation for a limit type when the agent has no
     *              per-agent override, preferring the value an administrator configured in
     *              AgentGov_Limit_Config__mdt over the built-in constant.
     * @param limitType One of the AgentGovConstants.LIMIT_* values
     * @param fallback The built-in default used when no metadata record supplies one
     * @return The allocation to write onto a new budget row
     */
    public static Decimal defaultAllocation(String limitType, Integer fallback) {
        return defaultAllocationFor(limitType, fallback);
    }

    private static Decimal defaultAllocationFor(String limitType, Integer fallback) {
        AgentGov_Limit_Config__mdt config = AgentGovSelector.getLimitConfigByType(limitType);
        return config != null && config.Default_Daily_Budget__c != null ? config.Default_Daily_Budget__c : fallback;
    }

    // --- Private helpers ---

    private static Map<Id, AgentGov_Budget__c> getOrCreateTodaysBudgets(
        Set<Id> registrationIds,
        Boolean forUpdate,
        Map<Id, AgentGovException> failures
    ) {
        Map<Id, AgentGov_Budget__c> budgets = forUpdate
            ? AgentGovSelector.getTodaysBudgetsForUpdate(registrationIds)
            : AgentGovSelector.getTodaysBudgets(registrationIds);

        Set<Id> missing = new Set<Id>();
        for (Id registrationId : registrationIds) {
            if (registrationId != null && !budgets.containsKey(registrationId)) {
                missing.add(registrationId);
            }
        }
        if (missing.isEmpty()) {
            return budgets;
        }

        Map<Id, AgentGov_Registration__c> registrations = AgentGovSelector.getRegistrationsByIds(missing);
        List<AgentGov_Budget__c> toInsert = new List<AgentGov_Budget__c>();
        Set<Id> created = new Set<Id>();
        Date today = Date.today();
        for (Id registrationId : missing) {
            AgentGov_Registration__c registration = registrations.get(registrationId);
            if (registration == null) {
                AgentGovException notFound = new AgentGovException(
                    AgentGovException.ErrorCode.AGENT_NOT_FOUND,
                    AgentGovConstants.ERR_AGENT_NOT_FOUND
                );
                if (failures == null) {
                    throw notFound;
                }
                failures.put(registrationId, notFound);
                continue;
            }
            toInsert.add(newBudgetFor(registration, today));
            created.add(registrationId);
        }
        if (toInsert.isEmpty()) {
            return budgets;
        }

        // Insert-and-catch rather than upsert: an upsert that matched a row created by a
        // concurrent transaction would overwrite that row's consumption with zeros, which
        // is exactly the double-spend this key exists to prevent.
        for (Database.SaveResult result : AgentGovDml.insertRecords(toInsert, false)) {
            if (!result.isSuccess() && !AgentGovDml.isDuplicateValueFailure(result)) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.INTERNAL_ERROR,
                    'Budget creation failed: ' + AgentGovDml.describeErrors(result.getErrors())
                );
            }
        }
        // Re-read so callers hold the persisted row (and its lock when requested),
        // including any row that another transaction inserted first.
        budgets.putAll(
            forUpdate ? AgentGovSelector.getTodaysBudgetsForUpdate(created) : AgentGovSelector.getTodaysBudgets(created)
        );
        return budgets;
    }

    private static AgentGov_Budget__c newBudgetFor(AgentGov_Registration__c registration, Date budgetDate) {
        return new AgentGov_Budget__c(
            Agent_Registration__c = registration.Id,
            Budget_Date__c = budgetDate,
            Budget_Key__c = buildBudgetKey(registration.Id, budgetDate),
            API_Calls_Allocated__c = registration.Daily_API_Budget__c != null
                ? registration.Daily_API_Budget__c
                : defaultAllocationFor(AgentGovConstants.LIMIT_API_CALLS, AgentGovConstants.DEFAULT_API_BUDGET),
            API_Calls_Consumed__c = 0,
            SOQL_Queries_Allocated__c = registration.Daily_SOQL_Budget__c != null
                ? registration.Daily_SOQL_Budget__c
                : defaultAllocationFor(AgentGovConstants.LIMIT_SOQL_QUERIES, AgentGovConstants.DEFAULT_SOQL_BUDGET),
            SOQL_Queries_Consumed__c = 0,
            DML_Operations_Allocated__c = registration.Daily_DML_Budget__c != null
                ? registration.Daily_DML_Budget__c
                : defaultAllocationFor(AgentGovConstants.LIMIT_DML_OPERATIONS, AgentGovConstants.DEFAULT_DML_BUDGET),
            DML_Operations_Consumed__c = 0,
            Budget_Status__c = AgentGovConstants.BUDGET_NORMAL
        );
    }

    private static Evaluation evaluate(AgentGov_Budget__c budget) {
        Evaluation evaluation = new Evaluation();
        for (String limitType : LIMIT_TYPES) {
            Decimal allocated = getAllocated(budget, limitType);
            Decimal consumed = getConsumed(budget, limitType);
            // A zero allocation means the limit type is not available to this agent, so any
            // consumption at all is treated as full usage.
            Decimal percent = allocated > 0 ? (consumed / allocated) * 100 : (consumed > 0 ? 100 : 0);
            String status = resolveStatus(percent, thresholdsFor(limitType));
            Boolean moreSevere = rank(status) > rank(evaluation.status);
            Boolean sameSeverityHigherUsage =
                rank(status) == rank(evaluation.status) &&
                percent > evaluation.worstPercent;
            if (evaluation.worstLimitType == null || moreSevere || sameSeverityHigherUsage) {
                evaluation.status = status;
                evaluation.worstLimitType = limitType;
                evaluation.worstPercent = percent;
                evaluation.worstConsumed = consumed;
                evaluation.worstAllocated = allocated;
            }
        }
        return evaluation;
    }

    private static Integer rank(String status) {
        Integer value = AgentGovConstants.BUDGET_STATUS_RANK.get(status);
        return value == null ? 0 : value;
    }

    private static Boolean isAllowed(String status) {
        return status != AgentGovConstants.BUDGET_BLOCKED && status != AgentGovConstants.BUDGET_EXHAUSTED;
    }

    private static AgentGovException validateConsumption(Map<String, Integer> consumption) {
        if (consumption == null || consumption.isEmpty()) {
            return new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, 'Consumption cannot be empty.');
        }
        for (String limitType : consumption.keySet()) {
            if (!AgentGovConstants.VALID_LIMIT_TYPES.contains(limitType)) {
                return new AgentGovException(
                    AgentGovException.ErrorCode.INVALID_INPUT,
                    AgentGovConstants.ERR_INVALID_LIMIT_TYPE + limitType
                );
            }
        }
        return null;
    }

    private static Decimal getAllocated(AgentGov_Budget__c budget, String limitType) {
        Decimal value;
        if (limitType == AgentGovConstants.LIMIT_API_CALLS) {
            value = budget.API_Calls_Allocated__c;
        } else if (limitType == AgentGovConstants.LIMIT_SOQL_QUERIES) {
            value = budget.SOQL_Queries_Allocated__c;
        } else {
            value = budget.DML_Operations_Allocated__c;
        }
        return value == null ? 0 : value;
    }

    private static Decimal getConsumed(AgentGov_Budget__c budget, String limitType) {
        Decimal value;
        if (limitType == AgentGovConstants.LIMIT_API_CALLS) {
            value = budget.API_Calls_Consumed__c;
        } else if (limitType == AgentGovConstants.LIMIT_SOQL_QUERIES) {
            value = budget.SOQL_Queries_Consumed__c;
        } else {
            value = budget.DML_Operations_Consumed__c;
        }
        return value == null ? 0 : value;
    }

    private static void setConsumed(AgentGov_Budget__c budget, String limitType, Decimal value) {
        if (limitType == AgentGovConstants.LIMIT_API_CALLS) {
            budget.API_Calls_Consumed__c = value;
        } else if (limitType == AgentGovConstants.LIMIT_SOQL_QUERIES) {
            budget.SOQL_Queries_Consumed__c = value;
        } else {
            budget.DML_Operations_Consumed__c = value;
        }
    }

    private static AgentGov_Alert__e buildAlert(
        Id registrationId,
        AgentGov_Registration__c registration,
        Evaluation evaluation
    ) {
        String alertType;
        if (evaluation.status == AgentGovConstants.BUDGET_WARNING) {
            alertType = AgentGovConstants.ALERT_WARNING;
        } else if (evaluation.status == AgentGovConstants.BUDGET_THROTTLED) {
            alertType = AgentGovConstants.ALERT_THROTTLE;
        } else {
            alertType = AgentGovConstants.ALERT_BLOCK;
        }
        return new AgentGov_Alert__e(
            Agent_Id__c = registrationId,
            Agent_Name__c = registration != null ? registration.Agent_Name__c : AgentGovConstants.UNKNOWN_AGENT_NAME,
            Alert_Type__c = alertType,
            Limit_Type__c = evaluation.worstLimitType,
            Current_Usage__c = evaluation.worstConsumed,
            Budget_Allocated__c = evaluation.worstAllocated,
            // Usage_Percentage__c is Number(5,2), so it tops out at 999.99. Overage is
            // persisted before a denial, which means the raw figure can exceed that and would
            // fail the publish outright. The exact number is on the budget row; the alert only
            // needs to say the ceiling was passed.
            Usage_Percentage__c = evaluation.worstPercent > MAX_ALERT_PERCENT
                ? MAX_ALERT_PERCENT
                : evaluation.worstPercent,
            Timestamp__c = DateTime.now()
        );
    }

    private static void updateSessionCounters(
        Map<Id, Map<String, Integer>> consumptionByAgent,
        Set<Id> registrationIds
    ) {
        Map<Id, AgentGov_Session__c> sessions = AgentGovSelector.getActiveSessionsByAgent(registrationIds);
        if (sessions.isEmpty()) {
            return;
        }
        List<AgentGov_Session__c> toUpdate = new List<AgentGov_Session__c>();
        for (Id registrationId : sessions.keySet()) {
            AgentGov_Session__c session = sessions.get(registrationId);
            Map<String, Integer> consumption = consumptionByAgent.get(registrationId);
            for (String limitType : consumption.keySet()) {
                Integer amount = consumption.get(limitType);
                if (amount == null || amount <= 0) {
                    continue;
                }
                if (limitType == AgentGovConstants.LIMIT_API_CALLS) {
                    session.API_Calls_Used__c =
                        (session.API_Calls_Used__c != null ? session.API_Calls_Used__c : 0) + amount;
                } else if (limitType == AgentGovConstants.LIMIT_SOQL_QUERIES) {
                    session.SOQL_Queries_Used__c =
                        (session.SOQL_Queries_Used__c != null ? session.SOQL_Queries_Used__c : 0) + amount;
                } else {
                    session.DML_Statements_Used__c =
                        (session.DML_Statements_Used__c != null ? session.DML_Statements_Used__c : 0) + amount;
                }
            }
            session.Actions_Count__c = (session.Actions_Count__c != null ? session.Actions_Count__c : 0) + 1;
            toUpdate.add(session);
        }
        // Session counters are secondary to the budget ledger: a failure here is recorded
        // for administrators but does not deny the agent's action.
        // Collected and written in one statement. Reporting each failure separately meant one
        // DML per failed session, so a systemic failure across a 200-agent batch exhausted the
        // DML statement limit and rolled the whole batch back.
        List<Database.SaveResult> results = AgentGovDml.updateRecords(toUpdate, false);
        List<AgentGov_Action_Log__c> notes = new List<AgentGov_Action_Log__c>();
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                notes.add(
                    AgentGovTriggerHandler.buildFrameworkEvent(
                        toUpdate[i].Agent_Registration__c,
                        AgentGovConstants.ACTION_FAILURE,
                        'Session counter update failed for session ' + toUpdate[i].Id,
                        AgentGovDml.describeErrors(results[i].getErrors())
                    )
                );
            }
        }
        AgentGovTriggerHandler.recordFrameworkEvents(notes);
    }

    private static BudgetResult buildBudgetResult(AgentGov_Budget__c budget) {
        BudgetResult result = new BudgetResult();
        result.budgetStatus = budget.Budget_Status__c;
        Decimal apiAllocated = getAllocated(budget, AgentGovConstants.LIMIT_API_CALLS);
        Decimal soqlAllocated = getAllocated(budget, AgentGovConstants.LIMIT_SOQL_QUERIES);
        Decimal dmlAllocated = getAllocated(budget, AgentGovConstants.LIMIT_DML_OPERATIONS);
        Decimal apiConsumed = getConsumed(budget, AgentGovConstants.LIMIT_API_CALLS);
        Decimal soqlConsumed = getConsumed(budget, AgentGovConstants.LIMIT_SOQL_QUERIES);
        Decimal dmlConsumed = getConsumed(budget, AgentGovConstants.LIMIT_DML_OPERATIONS);

        result.apiCallsRemaining = apiAllocated - apiConsumed;
        result.soqlQueriesRemaining = soqlAllocated - soqlConsumed;
        result.dmlOperationsRemaining = dmlAllocated - dmlConsumed;
        result.apiUsagePercent = apiAllocated > 0 ? (apiConsumed / apiAllocated) * 100 : 0;
        result.soqlUsagePercent = soqlAllocated > 0 ? (soqlConsumed / soqlAllocated) * 100 : 0;
        result.dmlUsagePercent = dmlAllocated > 0 ? (dmlConsumed / dmlAllocated) * 100 : 0;
        result.allowed = isAllowed(budget.Budget_Status__c);
        return result;
    }

    private static void requireId(Id registrationId) {
        if (registrationId == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_NULL_AGENT_ID);
        }
    }

    private static void requireLimitType(String limitType) {
        if (!AgentGovConstants.VALID_LIMIT_TYPES.contains(limitType)) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                AgentGovConstants.ERR_INVALID_LIMIT_TYPE + limitType
            );
        }
    }
}
