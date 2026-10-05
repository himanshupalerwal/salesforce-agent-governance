/**
 * @description Governed execution context for Apex-based agents.
 *
 *              Wraps a unit of agent work and measures the SOQL queries, DML statements, and
 *              callouts it actually consumed using the Limits class, then charges that
 *              measured amount to the agent's budget. Contexts nest: an inner context's
 *              consumption is charged to its own agent and excluded from the outer one. Each
 *              unit is recorded in the action log as an Apex row carrying its measured usage,
 *              its duration, and whether it succeeded, failed, or crossed the budget.
 *
 *              executeGoverned charges the measured usage even when the action throws, then
 *              rethrows the action's exception unchanged. A failed action still spent the
 *              org's resources, and if the caller lets the exception propagate the platform
 *              rolls the charge back with everything else. The unit's Apex row is then a
 *              Failure carrying the action's error, which also notes it when the charge took
 *              the agent over budget.
 *
 *              Security posture: inherited sharing. Registrations are read through
 *              AgentGovSelector, and the charge and the Apex rows are written by
 *              AgentGovBudgetManager and AgentGovTriggerHandler through AgentGovDml, all in
 *              system mode.
 */
public inherited sharing class AgentGovContext {
    private static List<AgentGovContext> contextStack = new List<AgentGovContext>();

    private Id registrationId;
    private Id sessionId;
    private Long startedAt;
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
     * @throws AgentGovException INVALID_INPUT for a null Id, AGENT_NOT_ACTIVE for a deactivated agent
     */
    public static AgentGovContext startTracking(Id registrationId) {
        return startTracking(registrationId, null);
    }

    /**
     * @description Starts measuring resource consumption for an agent within a session.
     * @param registrationId The agent registration Id
     * @param sessionId Optional session Id
     * @return The new context
     * @throws AgentGovException INVALID_INPUT for a null Id, AGENT_NOT_ACTIVE for a deactivated agent
     */
    public static AgentGovContext startTracking(Id registrationId, Id sessionId) {
        if (registrationId == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_NULL_AGENT_ID);
        }
        // Deactivation refuses an agent on every governed entry point, Apex included. The check is
        // governance overhead: its query is taken before this context's baseline and removed
        // from every enclosing context, so no agent is charged for it.
        Integer queriesBefore = Limits.getQueries();
        AgentGov_Registration__c registration = AgentGovSelector.getRegistrationsByIds(new Set<Id>{ registrationId })
            .get(registrationId);
        Integer overhead = Limits.getQueries() - queriesBefore;
        for (AgentGovContext open : contextStack) {
            open.startQueries += overhead;
        }
        if (registration != null && registration.Status__c == AgentGovConstants.STATUS_INACTIVE) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.AGENT_NOT_ACTIVE,
                AgentGovConstants.ERR_AGENT_NOT_ACTIVE
            );
        }
        AgentGovContext context = new AgentGovContext();
        context.registrationId = registrationId;
        context.sessionId = sessionId;
        context.startedAt = System.currentTimeMillis();
        context.startQueries = Limits.getQueries();
        context.startDml = Limits.getDmlStatements();
        context.startCallouts = Limits.getCallouts();
        contextStack.add(context);
        return context;
    }

    /**
     * @description Stops the innermost context and charges its measured consumption.
     * @return The budget after the charge
     * @throws AgentGovException INVALID_INPUT when no context is active, BUDGET_EXCEEDED when the charge leaves the budget Blocked or Exhausted
     */
    public static AgentGovBudgetManager.BudgetResult stopTracking() {
        return stop(null);
    }

    /**
     * Stops the innermost context, charges its consumption, and records the unit in the
     * action log. failure is the action's error message when the unit threw, otherwise null.
     */
    private static AgentGovBudgetManager.BudgetResult stop(String failure) {
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
        String status = failure == null ? AgentGovConstants.ACTION_SUCCESS : AgentGovConstants.ACTION_FAILURE;
        String error = failure;
        try {
            // With governance switched off the usage is measured and reported but not charged,
            // so the emergency bypass cannot leave an Apex agent blocked mid-migration.
            if (consumption.isEmpty() || !AgentGovSelector.isFrameworkEnabled()) {
                return AgentGovBudgetManager.checkBudget(context.registrationId);
            }
            return AgentGovBudgetManager.consumeBudget(context.registrationId, consumption);
        } catch (AgentGovException denied) {
            // A unit whose action failed keeps that failure as its outcome, so the action's own
            // error stays on the row and what the charge raised is added after it.
            if (failure == null) {
                status = AgentGovConstants.ACTION_DENIED;
                error = denied.getMessage();
            } else if (isBudgetDenial(denied)) {
                error = failure + '\nIts usage was charged and took the agent over budget: ' + denied.getMessage();
            } else {
                error = failure + '\nIts usage could not be charged: ' + denied.getMessage();
            }
            throw denied;
        } finally {
            // Written inside the bookkeeping window, so the enclosing agent is not charged for
            // the audit row either.
            logUnit(context, status, consumption, error);
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

    /**
     * @description Returns the agent this context measures.
     * @return The agent registration Id
     */
    public Id getRegistrationId() {
        return this.registrationId;
    }

    /**
     * @description Returns the session this context was started with.
     * @return The session Id, or null when none was given
     */
    public Id getSessionId() {
        return this.sessionId;
    }

    /**
     * @description Runs an action under measurement and charges its consumption.
     * @param registrationId The agent registration Id
     * @param action The work to run
     * @return The budget after the charge
     * @throws AgentGovException INVALID_INPUT for a null Id or AGENT_NOT_ACTIVE for a deactivated agent, before the action runs; BUDGET_EXCEEDED when the action succeeds and its usage leaves the budget Blocked or Exhausted
     * @throws Exception whatever the action throws, after its measured usage has been charged
     */
    public static AgentGovBudgetManager.BudgetResult executeGoverned(Id registrationId, AgentGovAction action) {
        startTracking(registrationId);
        try {
            action.execute();
        } catch (Exception actionFailure) {
            chargeAfterFailure(registrationId, actionFailure.getTypeName() + ': ' + actionFailure.getMessage());
            throw actionFailure;
        }
        return stopTracking();
    }

    // One Apex row per unit of work, carrying the unit's own duration rather than that of the
    // enclosing request.
    private static void logUnit(
        AgentGovContext context,
        String status,
        Map<String, Integer> consumption,
        String error
    ) {
        AgentGov_Registration__c agent = AgentGovSelector.getRegistrationById(context.registrationId);
        AgentGov_Action_Event__e event = AgentGovTriggerHandler.buildEvent(
            context.registrationId,
            agent != null ? agent.Agent_Name__c : AgentGovConstants.UNKNOWN_AGENT_NAME,
            AgentGovConstants.ACTION_APEX,
            null,
            null,
            status,
            JSON.serialize(consumption)
        );
        event.Execution_Time_Ms__c = System.currentTimeMillis() - context.startedAt;
        event.Error_Message__c = error;
        AgentGovTriggerHandler.logActions(new List<AgentGov_Action_Event__e>{ event });
    }

    /** @description Clears every active context. For tests only. */
    @TestVisible
    private static void resetForTest() {
        contextStack.clear();
    }

    // Charges the failed action's measured usage. Nothing raised here is propagated: the
    // action's own exception is the one the caller must see. Crossing the budget is not a
    // bookkeeping failure, because the usage was charged and the unit's Apex row records it
    // next to the action's error; anything else is recorded as a System row.
    @SuppressWarnings('PMD.EmptyCatchBlock')
    private static void chargeAfterFailure(Id registrationId, String failure) {
        // Catches everything, not just AgentGovException. The caller is on its way to
        // rethrowing the action's own exception, and anything escaping here would replace it
        // with a bookkeeping error, hiding the real failure from the agent.
        try {
            stop(failure);
        } catch (Exception bookkeepingFailure) {
            if (isBudgetDenial(bookkeepingFailure)) {
                return;
            }
            try {
                AgentGovTriggerHandler.recordFrameworkEvent(
                    AgentGovSelector.getRegistrationById(registrationId) != null ? registrationId : null,
                    AgentGovConstants.ACTION_FAILURE,
                    'A failed governed action could not be fully recorded: ' + bookkeepingFailure.getMessage(),
                    null
                );
            } catch (Exception unloggable) {
                // Deliberately empty. The note could not itself be written, and nothing useful
                // remains to be done: the caller is about to rethrow the agent's own exception,
                // which must not be replaced by this one.
            }
        }
    }

    private static Boolean isBudgetDenial(Exception failure) {
        return failure instanceof AgentGovException &&
            ((AgentGovException) failure).getErrorCode() == AgentGovException.ErrorCode.BUDGET_EXCEEDED;
    }
}
