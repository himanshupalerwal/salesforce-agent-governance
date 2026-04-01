/**
 * @description Manages governor limit budgets for AI agents. Allocates, tracks,
 *              and enforces daily limits on API calls, SOQL queries, and DML operations.
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovBudgetManager {

    /**
     * @description Result object for budget check operations.
     */
    public class BudgetResult {
        @AuraEnabled public Boolean allowed;
        @AuraEnabled public String budgetStatus;
        @AuraEnabled public Decimal apiCallsRemaining;
        @AuraEnabled public Decimal soqlQueriesRemaining;
        @AuraEnabled public Decimal dmlOperationsRemaining;
        @AuraEnabled public Decimal apiUsagePercent;
        @AuraEnabled public Decimal soqlUsagePercent;
        @AuraEnabled public Decimal dmlUsagePercent;
    }

    /**
     * @description Checks if an agent has budget remaining. Does NOT consume budget.
     * @param registrationId The agent registration ID
     * @return BudgetResult with remaining budget details
     */
    public static BudgetResult checkBudget(Id registrationId) {
        if (registrationId == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_NULL_AGENT_ID);
        }

        AgentGov_Budget__c budget = getOrCreateTodaysBudget(registrationId, false);
        return buildBudgetResult(budget);
    }

    /**
     * @description Consumes budget for an agent action. Fires alerts at thresholds.
     * @param registrationId The agent registration ID
     * @param limitType The type of limit being consumed (use AgentGovConstants.LIMIT_*)
     * @param amount The amount to consume
     * @return BudgetResult after consumption
     */
    public static BudgetResult consumeBudget(Id registrationId, String limitType, Integer amount) {
        if (registrationId == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_NULL_AGENT_ID);
        }

        // Get budget with FOR UPDATE lock to prevent race conditions
        AgentGov_Budget__c budget = getOrCreateTodaysBudget(registrationId, true);

        Decimal allocated = 0;
        Decimal consumed = 0;

        if (limitType == AgentGovConstants.LIMIT_API_CALLS) {
            allocated = budget.API_Calls_Allocated__c;
            consumed = budget.API_Calls_Consumed__c + amount;
            budget.API_Calls_Consumed__c = consumed;
        } else if (limitType == AgentGovConstants.LIMIT_SOQL_QUERIES) {
            allocated = budget.SOQL_Queries_Allocated__c;
            consumed = budget.SOQL_Queries_Consumed__c + amount;
            budget.SOQL_Queries_Consumed__c = consumed;
        } else if (limitType == AgentGovConstants.LIMIT_DML_OPERATIONS) {
            allocated = budget.DML_Operations_Allocated__c;
            consumed = budget.DML_Operations_Consumed__c + amount;
            budget.DML_Operations_Consumed__c = consumed;
        }

        // Calculate usage percentage
        Decimal usagePercent = allocated > 0 ? (consumed / allocated) * 100 : 100;

        // Get thresholds
        AgentGov_Limit_Config__mdt config = AgentGovSelector.getLimitConfigByType(limitType);
        Decimal warningThreshold = config != null && config.Warning_Threshold__c != null
            ? config.Warning_Threshold__c : AgentGovConstants.DEFAULT_WARNING_THRESHOLD;
        Decimal throttleThreshold = config != null && config.Throttle_Threshold__c != null
            ? config.Throttle_Threshold__c : AgentGovConstants.DEFAULT_THROTTLE_THRESHOLD;
        Decimal blockThreshold = config != null && config.Block_Threshold__c != null
            ? config.Block_Threshold__c : AgentGovConstants.DEFAULT_BLOCK_THRESHOLD;

        // Determine new budget status and fire alerts
        String previousStatus = budget.Budget_Status__c;

        if (usagePercent >= 100) {
            budget.Budget_Status__c = AgentGovConstants.BUDGET_EXHAUSTED;
            fireAlert(registrationId, AgentGovConstants.ALERT_BLOCK, limitType, consumed, allocated, usagePercent);
            throw new AgentGovException(AgentGovException.ErrorCode.BUDGET_EXCEEDED, AgentGovConstants.ERR_BUDGET_EXCEEDED + limitType);
        } else if (usagePercent >= blockThreshold) {
            budget.Budget_Status__c = AgentGovConstants.BUDGET_BLOCKED;
            fireAlert(registrationId, AgentGovConstants.ALERT_BLOCK, limitType, consumed, allocated, usagePercent);
            update budget;
            throw new AgentGovException(AgentGovException.ErrorCode.BUDGET_EXCEEDED, AgentGovConstants.ERR_BUDGET_EXCEEDED + limitType);
        } else if (usagePercent >= throttleThreshold) {
            budget.Budget_Status__c = AgentGovConstants.BUDGET_THROTTLED;
            if (previousStatus != AgentGovConstants.BUDGET_THROTTLED) {
                fireAlert(registrationId, AgentGovConstants.ALERT_THROTTLE, limitType, consumed, allocated, usagePercent);
            }
        } else if (usagePercent >= warningThreshold) {
            budget.Budget_Status__c = AgentGovConstants.BUDGET_WARNING;
            if (previousStatus != AgentGovConstants.BUDGET_WARNING && previousStatus != AgentGovConstants.BUDGET_THROTTLED) {
                fireAlert(registrationId, AgentGovConstants.ALERT_WARNING, limitType, consumed, allocated, usagePercent);
            }
        }

        update budget;
        return buildBudgetResult(budget);
    }

    /**
     * @description Gets remaining budget for an agent.
     * @param registrationId The agent registration ID
     * @return BudgetResult with remaining amounts
     */
    public static BudgetResult getRemainingBudget(Id registrationId) {
        return checkBudget(registrationId);
    }

    /**
     * @description Creates a daily budget record for an agent using defaults from registration and config.
     * @param registrationId The agent registration ID
     * @return The created budget record
     */
    public static AgentGov_Budget__c createDailyBudget(Id registrationId) {
        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById(registrationId);
        if (reg == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.AGENT_NOT_FOUND, AgentGovConstants.ERR_AGENT_NOT_FOUND);
        }

        AgentGov_Budget__c budget = new AgentGov_Budget__c(
            Agent_Registration__c = registrationId,
            Budget_Date__c = Date.today(),
            API_Calls_Allocated__c = reg.Daily_API_Budget__c != null ? reg.Daily_API_Budget__c : AgentGovConstants.DEFAULT_API_BUDGET,
            API_Calls_Consumed__c = 0,
            SOQL_Queries_Allocated__c = reg.Daily_SOQL_Budget__c != null ? reg.Daily_SOQL_Budget__c : AgentGovConstants.DEFAULT_SOQL_BUDGET,
            SOQL_Queries_Consumed__c = 0,
            DML_Operations_Allocated__c = reg.Daily_DML_Budget__c != null ? reg.Daily_DML_Budget__c : AgentGovConstants.DEFAULT_DML_BUDGET,
            DML_Operations_Consumed__c = 0,
            Budget_Status__c = AgentGovConstants.BUDGET_NORMAL
        );
        insert budget;
        return budget;
    }

    /**
     * @description Resets daily budgets for all active agents. Called by scheduled job.
     */
    public static void resetDailyBudgets() {
        List<AgentGov_Registration__c> activeAgents = AgentGovSelector.getActiveRegistrations();
        List<AgentGov_Budget__c> newBudgets = new List<AgentGov_Budget__c>();
        Date today = Date.today();

        for (AgentGov_Registration__c reg : activeAgents) {
            newBudgets.add(new AgentGov_Budget__c(
                Agent_Registration__c = reg.Id,
                Budget_Date__c = today,
                API_Calls_Allocated__c = reg.Daily_API_Budget__c != null ? reg.Daily_API_Budget__c : AgentGovConstants.DEFAULT_API_BUDGET,
                API_Calls_Consumed__c = 0,
                SOQL_Queries_Allocated__c = reg.Daily_SOQL_Budget__c != null ? reg.Daily_SOQL_Budget__c : AgentGovConstants.DEFAULT_SOQL_BUDGET,
                SOQL_Queries_Consumed__c = 0,
                DML_Operations_Allocated__c = reg.Daily_DML_Budget__c != null ? reg.Daily_DML_Budget__c : AgentGovConstants.DEFAULT_DML_BUDGET,
                DML_Operations_Consumed__c = 0,
                Budget_Status__c = AgentGovConstants.BUDGET_NORMAL
            ));
        }

        if (!newBudgets.isEmpty()) {
            Database.insert(newBudgets, false);
        }
    }

    // --- Private helpers ---

    private static AgentGov_Budget__c getOrCreateTodaysBudget(Id registrationId, Boolean forUpdate) {
        AgentGov_Budget__c budget = forUpdate
            ? AgentGovSelector.getTodaysBudgetForUpdate(registrationId)
            : AgentGovSelector.getTodaysBudget(registrationId);

        if (budget == null) {
            budget = createDailyBudget(registrationId);
            if (forUpdate) {
                budget = AgentGovSelector.getTodaysBudgetForUpdate(registrationId);
            }
        }
        return budget;
    }

    private static BudgetResult buildBudgetResult(AgentGov_Budget__c budget) {
        BudgetResult result = new BudgetResult();
        result.budgetStatus = budget.Budget_Status__c;
        result.apiCallsRemaining = (budget.API_Calls_Allocated__c != null ? budget.API_Calls_Allocated__c : 0)
            - (budget.API_Calls_Consumed__c != null ? budget.API_Calls_Consumed__c : 0);
        result.soqlQueriesRemaining = (budget.SOQL_Queries_Allocated__c != null ? budget.SOQL_Queries_Allocated__c : 0)
            - (budget.SOQL_Queries_Consumed__c != null ? budget.SOQL_Queries_Consumed__c : 0);
        result.dmlOperationsRemaining = (budget.DML_Operations_Allocated__c != null ? budget.DML_Operations_Allocated__c : 0)
            - (budget.DML_Operations_Consumed__c != null ? budget.DML_Operations_Consumed__c : 0);

        Decimal apiAllocated = budget.API_Calls_Allocated__c != null ? budget.API_Calls_Allocated__c : 1;
        Decimal soqlAllocated = budget.SOQL_Queries_Allocated__c != null ? budget.SOQL_Queries_Allocated__c : 1;
        Decimal dmlAllocated = budget.DML_Operations_Allocated__c != null ? budget.DML_Operations_Allocated__c : 1;

        result.apiUsagePercent = apiAllocated > 0
            ? ((budget.API_Calls_Consumed__c != null ? budget.API_Calls_Consumed__c : 0) / apiAllocated) * 100 : 0;
        result.soqlUsagePercent = soqlAllocated > 0
            ? ((budget.SOQL_Queries_Consumed__c != null ? budget.SOQL_Queries_Consumed__c : 0) / soqlAllocated) * 100 : 0;
        result.dmlUsagePercent = dmlAllocated > 0
            ? ((budget.DML_Operations_Consumed__c != null ? budget.DML_Operations_Consumed__c : 0) / dmlAllocated) * 100 : 0;

        result.allowed = budget.Budget_Status__c != AgentGovConstants.BUDGET_BLOCKED
            && budget.Budget_Status__c != AgentGovConstants.BUDGET_EXHAUSTED;

        return result;
    }

    private static void fireAlert(Id registrationId, String alertType, String limitType, Decimal currentUsage, Decimal allocated, Decimal usagePercent) {
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        if (settings.Enable_Real_Time_Events__c == false) {
            return;
        }

        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById(registrationId);
        AgentGov_Alert__e alert = new AgentGov_Alert__e(
            Agent_Id__c = registrationId,
            Agent_Name__c = reg != null ? reg.Agent_Name__c : 'Unknown',
            Alert_Type__c = alertType,
            Limit_Type__c = limitType,
            Current_Usage__c = currentUsage,
            Budget_Allocated__c = allocated,
            Usage_Percentage__c = usagePercent,
            Timestamp__c = DateTime.now()
        );

        Database.SaveResult sr = EventBus.publish(alert);
        if (!sr.isSuccess()) {
            System.debug(LoggingLevel.ERROR, 'AgentGov: Failed to publish alert event: ' + sr.getErrors());
        }
    }
}
