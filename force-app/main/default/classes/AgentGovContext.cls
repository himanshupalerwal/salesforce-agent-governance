/**
 * @description Governed execution context for Apex-based agents.
 *
 *              Wraps a unit of agent work and measures the SOQL queries, DML statements, and
 *              callouts it actually consumed using the Limits class, then charges that
 *              measured amount to the agent's budget. Contexts nest: an inner context's
 *              consumption is charged to its own agent and excluded from the outer one.
 *
 *              executeGoverned charges the measured usage even when the action throws, then
 *              rethrows the action's exception unchanged. A failed action still spent the
 *              org's resources, and if the caller lets the exception propagate the platform
 *              rolls the charge back with everything else.
 *
 *              Security posture: inherited sharing. Budget writes go through
 *              AgentGovBudgetManager, which runs in system mode.
 */
public inherited sharing class AgentGovContext {
    private static List<AgentGovContext> contextStack = new List<AgentGovContext>();

    private Id registrationId;
    private Id sessionId;
    private Integer startQueries;
    private Integer startDml;
    private Integer startCallouts;

    /** @description A unit of agent work to run under measurement. */
    public interface AgentGovAction {
        void execute();
    }

    /**
     * @description Starts measuring resource consumption for an agent.
     * @param registrationId The agent registration Id
     * @return The new context
     * @throws AgentGovException INVALID_INPUT for a null Id
     */
    public static AgentGovContext startTracking(Id registrationId) {
        return startTracking(registrationId, null);
    }

    /**
     * @description Starts measuring resource consumption for an agent within a session.
     * @param registrationId The agent registration Id
     * @param sessionId Optional session Id
     * @return The new context
     * @throws AgentGovException INVALID_INPUT for a null Id
     */
    public static AgentGovContext startTracking(Id registrationId, Id sessionId) {
        if (registrationId == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_NULL_AGENT_ID);
        }
        AgentGovContext context = new AgentGovContext();
        context.registrationId = registrationId;
        context.sessionId = sessionId;
        context.startQueries = Limits.getQueries();
        context.startDml = Limits.getDmlStatements();
        context.startCallouts = Limits.getCallouts();
        contextStack.add(context);
        return context;
    }

    /**
     * @description Stops the innermost context and charges its measured consumption.
     * @return The budget after the charge
     * @throws AgentGovException INVALID_INPUT when no context is active, BUDGET_EXCEEDED when the charge exhausts the budget
     */
    public static AgentGovBudgetManager.BudgetResult stopTracking() {
        AgentGovContext context = getCurrentContext();
        if (context == null) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                'No active AgentGov tracking context. Call startTracking() first.'
            );
        }
        contextStack.remove(contextStack.size() - 1);

        Integer queriesDelta = Limits.getQueries() - context.startQueries;
        Integer dmlDelta = Limits.getDmlStatements() - context.startDml;
        Integer calloutsDelta = Limits.getCallouts() - context.startCallouts;

        // Whatever the inner context consumed belongs to its agent, not to the enclosing one.
        AgentGovContext parent = getCurrentContext();
        if (parent != null) {
            parent.startQueries += queriesDelta;
            parent.startDml += dmlDelta;
            parent.startCallouts += calloutsDelta;
        }

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

        // The framework's own bookkeeping for this charge must not be billed to the
        // enclosing agent either, so its cost is excluded from the parent as well.
        Integer bookkeepingQueries = Limits.getQueries();
        Integer bookkeepingDml = Limits.getDmlStatements();
        try {
            // With governance switched off the usage is measured and reported but not charged,
            // so the emergency bypass cannot leave an Apex agent blocked mid-migration.
            if (consumption.isEmpty() || !AgentGovSelector.isFrameworkEnabled()) {
                return AgentGovBudgetManager.checkBudget(context.registrationId);
            }
            return AgentGovBudgetManager.consumeBudget(context.registrationId, consumption);
        } finally {
            if (parent != null) {
                parent.startQueries += Limits.getQueries() - bookkeepingQueries;
                parent.startDml += Limits.getDmlStatements() - bookkeepingDml;
            }
        }
    }

    /**
     * @description Returns the innermost active context, or null. Triggers can use it to
     *              identify the acting agent.
     * @return The current context or null
     */
    public static AgentGovContext getCurrentContext() {
        return contextStack.isEmpty() ? null : contextStack[contextStack.size() - 1];
    }

    /** @description The agent this context measures. */
    public Id getRegistrationId() {
        return this.registrationId;
    }

    /** @description The session this context was started with, if any. */
    public Id getSessionId() {
        return this.sessionId;
    }

    /**
     * @description Runs an action under measurement and charges its consumption.
     * @param registrationId The agent registration Id
     * @param action The work to run
     * @return The budget after the charge
     * @throws Exception whatever the action throws, after the measured usage has been charged
     */
    public static AgentGovBudgetManager.BudgetResult executeGoverned(Id registrationId, AgentGovAction action) {
        startTracking(registrationId);
        try {
            action.execute();
        } catch (Exception actionFailure) {
            chargeAfterFailure();
            throw actionFailure;
        }
        return stopTracking();
    }

    /** @description Clears every active context. For tests only. */
    @TestVisible
    private static void resetForTest() {
        contextStack.clear();
    }

    // Charges the failed action's measured usage. A budget exception raised here is
    // deliberately not propagated: the action's own exception is the one the caller must
    // see, and the budget row has already been written by the time it is raised.
    private static void chargeAfterFailure() {
        // Catches everything, not just AgentGovException. The caller is on its way to
        // rethrowing the action's own exception, and anything escaping here would replace it
        // with a bookkeeping error, hiding the real failure from the agent.
        try {
            stopTracking();
        } catch (Exception bookkeepingFailure) {
            try {
                AgentGovTriggerHandler.recordFrameworkEvent(
                    null,
                    AgentGovConstants.ACTION_FAILURE,
                    'Usage could not be charged after a governed action failed: ' + bookkeepingFailure.getMessage(),
                    null
                );
            } catch (Exception unloggable) {
                // Nothing further can be done. Losing the note is preferable to losing the
                // agent's own exception, which the caller is about to rethrow.
            }
        }
    }
}
