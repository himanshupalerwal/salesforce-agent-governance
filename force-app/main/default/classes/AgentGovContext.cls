/**
 * @description Provides a governed execution context for Apex-based agents.
 *              Wraps agent work and uses the Limits class to measure actual
 *              SOQL queries, DML statements, and callouts consumed during execution.
 *              Budget is consumed based on real measured amounts, not self-reported.
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovContext {

    @TestVisible
    private static AgentGovContext currentContext;

    private Id registrationId;
    private Id sessionId;
    private Integer startQueries;
    private Integer startDml;
    private Integer startCallouts;
    private Boolean isActive = false;

    /**
     * @description Functional interface for governed execution.
     */
    public interface AgentGovAction {
        void execute();
    }

    /**
     * @description Starts tracking resource consumption for an agent.
     * @param registrationId The agent registration ID
     * @return The active context (for chaining or inspection)
     */
    public static AgentGovContext startTracking(Id registrationId) {
        return startTracking(registrationId, null);
    }

    /**
     * @description Starts tracking resource consumption for an agent with a session.
     * @param registrationId The agent registration ID
     * @param sessionId The optional session ID
     * @return The active context
     */
    public static AgentGovContext startTracking(Id registrationId, Id sessionId) {
        if (registrationId == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_NULL_AGENT_ID);
        }

        AgentGovContext ctx = new AgentGovContext();
        ctx.registrationId = registrationId;
        ctx.sessionId = sessionId;
        ctx.startQueries = Limits.getQueries();
        ctx.startDml = Limits.getDmlStatements();
        ctx.startCallouts = Limits.getCallouts();
        ctx.isActive = true;
        currentContext = ctx;
        return ctx;
    }

    /**
     * @description Stops tracking and consumes budget based on actual measured delta.
     * @return BudgetResult reflecting actual consumption
     */
    public static AgentGovBudgetManager.BudgetResult stopTracking() {
        if (currentContext == null || !currentContext.isActive) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                'No active AgentGov tracking context. Call startTracking() first.'
            );
        }

        Integer queriesDelta = Limits.getQueries() - currentContext.startQueries;
        Integer dmlDelta = Limits.getDmlStatements() - currentContext.startDml;
        Integer calloutsDelta = Limits.getCallouts() - currentContext.startCallouts;

        Map<String, Integer> consumption = new Map<String, Integer>();
        if (queriesDelta > 0) {
            consumption.put(AgentGovConstants.LIMIT_SOQL_QUERIES, queriesDelta);
        }
        if (dmlDelta > 0) {
            consumption.put(AgentGovConstants.LIMIT_DML_OPERATIONS, dmlDelta);
        }
        if (calloutsDelta > 0) {
            consumption.put(AgentGovConstants.LIMIT_API_CALLS, calloutsDelta);
        }

        currentContext.isActive = false;
        Id regId = currentContext.registrationId;
        currentContext = null;

        if (consumption.isEmpty()) {
            return AgentGovBudgetManager.checkBudget(regId);
        }

        return AgentGovBudgetManager.consumeBudget(regId, consumption);
    }

    /**
     * @description Returns the currently active context (if any).
     *              Useful for triggers to identify the acting agent.
     * @return The current context, or null if no tracking is active
     */
    public static AgentGovContext getCurrentContext() {
        return currentContext;
    }

    /**
     * @description Returns the registration ID of the currently tracked agent.
     * @return The registration ID, or null if no context is active
     */
    public Id getRegistrationId() {
        return this.registrationId;
    }

    /**
     * @description Executes an action within a governed context.
     *              Automatically starts tracking, executes the action, and stops tracking.
     *              Budget is consumed based on actual measured resource usage.
     * @param registrationId The agent registration ID
     * @param action The action to execute
     * @return BudgetResult reflecting actual consumption
     */
    public static AgentGovBudgetManager.BudgetResult executeGoverned(Id registrationId, AgentGovAction action) {
        startTracking(registrationId);
        try {
            action.execute();
        } finally {
            // Always stop tracking even if action throws
            if (currentContext != null && currentContext.isActive) {
                return stopTracking();
            }
        }
        return AgentGovBudgetManager.checkBudget(registrationId);
    }
}
