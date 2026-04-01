/**
 * @description Implements the Circuit Breaker pattern for AI agent health monitoring.
 *              Automatically disables misbehaving agents and provides recovery mechanisms.
 *              States: CLOSED (normal) → OPEN (blocked) → HALF_OPEN (testing) → CLOSED
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovCircuitBreaker {

    /**
     * @description Checks if an agent is allowed to make a request based on circuit breaker state.
     * @param registrationId The agent registration ID
     * @return True if the request is allowed
     */
    public static Boolean allowRequest(Id registrationId) {
        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById(registrationId);
        if (reg == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.AGENT_NOT_FOUND, AgentGovConstants.ERR_AGENT_NOT_FOUND);
        }

        String state = reg.Circuit_Breaker_State__c != null ? reg.Circuit_Breaker_State__c : AgentGovConstants.CB_CLOSED;

        if (state == AgentGovConstants.CB_CLOSED) {
            return true;
        }

        if (state == AgentGovConstants.CB_OPEN) {
            // Check if cooldown has elapsed
            if (reg.Cooldown_Until__c != null && DateTime.now() >= reg.Cooldown_Until__c) {
                // Transition to HALF_OPEN
                transitionToHalfOpen(reg);
                return true;
            }
            return false;
        }

        if (state == AgentGovConstants.CB_HALF_OPEN) {
            // Allow one test request
            return true;
        }

        return false;
    }

    /**
     * @description Records a successful action for the circuit breaker.
     *              In HALF_OPEN state, resets the circuit breaker to CLOSED.
     * @param registrationId The agent registration ID
     */
    public static void recordSuccess(Id registrationId) {
        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById(registrationId);
        if (reg == null) {
            return;
        }

        String state = reg.Circuit_Breaker_State__c != null ? reg.Circuit_Breaker_State__c : AgentGovConstants.CB_CLOSED;

        if (state == AgentGovConstants.CB_HALF_OPEN) {
            // Recovery successful — close the circuit breaker
            reg.Circuit_Breaker_State__c = AgentGovConstants.CB_CLOSED;
            reg.Failure_Count__c = 0;
            reg.Last_Failure__c = null;
            reg.Cooldown_Until__c = null;
            if (reg.Status__c == AgentGovConstants.STATUS_THROTTLED || reg.Status__c == AgentGovConstants.STATUS_BLOCKED) {
                reg.Status__c = AgentGovConstants.STATUS_ACTIVE;
            }
            update reg;
            AgentGovSelector.clearCache();
        }
    }

    /**
     * @description Records a failed action for the circuit breaker.
     *              Increments failure count and trips breaker if threshold exceeded.
     * @param registrationId The agent registration ID
     */
    public static void recordFailure(Id registrationId) {
        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById(registrationId);
        if (reg == null) {
            return;
        }

        String state = reg.Circuit_Breaker_State__c != null ? reg.Circuit_Breaker_State__c : AgentGovConstants.CB_CLOSED;

        if (state == AgentGovConstants.CB_HALF_OPEN) {
            // Test request failed — back to OPEN with extended cooldown
            tripBreaker(reg, true);
            return;
        }

        // Increment failure count
        reg.Failure_Count__c = (reg.Failure_Count__c != null ? reg.Failure_Count__c : 0) + 1;
        reg.Last_Failure__c = DateTime.now();

        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        Integer threshold = settings.Circuit_Breaker_Failure_Threshold__c != null
            ? (Integer) settings.Circuit_Breaker_Failure_Threshold__c
            : AgentGovConstants.DEFAULT_CB_FAILURE_THRESHOLD;

        if (reg.Failure_Count__c >= threshold) {
            tripBreaker(reg, false);
        } else {
            update reg;
            AgentGovSelector.clearCache();
        }
    }

    /**
     * @description Gets the current circuit breaker state for an agent.
     * @param registrationId The agent registration ID
     * @return The circuit breaker state string
     */
    public static String getState(Id registrationId) {
        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById(registrationId);
        if (reg == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.AGENT_NOT_FOUND, AgentGovConstants.ERR_AGENT_NOT_FOUND);
        }
        return reg.Circuit_Breaker_State__c != null ? reg.Circuit_Breaker_State__c : AgentGovConstants.CB_CLOSED;
    }

    /**
     * @description Manually resets a circuit breaker to CLOSED state.
     * @param registrationId The agent registration ID
     */
    public static void resetBreaker(Id registrationId) {
        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById(registrationId);
        if (reg == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.AGENT_NOT_FOUND, AgentGovConstants.ERR_AGENT_NOT_FOUND);
        }
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_CLOSED;
        reg.Failure_Count__c = 0;
        reg.Last_Failure__c = null;
        reg.Cooldown_Until__c = null;
        if (reg.Status__c == AgentGovConstants.STATUS_BLOCKED) {
            reg.Status__c = AgentGovConstants.STATUS_ACTIVE;
        }
        update reg;
        AgentGovSelector.clearCache();
    }

    // --- Private helpers ---

    private static void tripBreaker(AgentGov_Registration__c reg, Boolean isRetry) {
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        Integer cooldownMinutes = settings.Circuit_Breaker_Cooldown_Minutes__c != null
            ? (Integer) settings.Circuit_Breaker_Cooldown_Minutes__c
            : AgentGovConstants.DEFAULT_CB_COOLDOWN_MINUTES;

        // Exponential backoff on retry
        if (isRetry) {
            cooldownMinutes = cooldownMinutes * 2;
        }

        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        reg.Status__c = AgentGovConstants.STATUS_BLOCKED;
        reg.Cooldown_Until__c = DateTime.now().addMinutes(cooldownMinutes);
        update reg;
        AgentGovSelector.clearCache();

        // Fire alert
        fireCircuitBreakerAlert(reg);
    }

    private static void transitionToHalfOpen(AgentGov_Registration__c reg) {
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_HALF_OPEN;
        if (reg.Status__c == AgentGovConstants.STATUS_BLOCKED) {
            reg.Status__c = AgentGovConstants.STATUS_THROTTLED;
        }
        update reg;
        AgentGovSelector.clearCache();
    }

    private static void fireCircuitBreakerAlert(AgentGov_Registration__c reg) {
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        if (settings.Enable_Real_Time_Events__c == false) {
            return;
        }

        AgentGov_Alert__e alert = new AgentGov_Alert__e(
            Agent_Id__c = reg.Id,
            Agent_Name__c = reg.Agent_Name__c,
            Alert_Type__c = AgentGovConstants.ALERT_BLOCK,
            Limit_Type__c = 'Circuit_Breaker',
            Current_Usage__c = reg.Failure_Count__c,
            Budget_Allocated__c = AgentGovSelector.getSettings().Circuit_Breaker_Failure_Threshold__c,
            Usage_Percentage__c = 100,
            Timestamp__c = DateTime.now()
        );

        Database.SaveResult sr = EventBus.publish(alert);
        if (!sr.isSuccess()) {
            System.debug(LoggingLevel.ERROR, 'AgentGov: Failed to publish circuit breaker alert: ' + sr.getErrors());
        }
    }
}
