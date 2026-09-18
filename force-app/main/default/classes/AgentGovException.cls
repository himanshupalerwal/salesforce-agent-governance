/**
 * @description Custom exception for the AgentGov framework.
 *              Carries a typed error code that maps to an HTTP status so REST callers,
 *              invocable actions, and Apex callers all receive the same classification.
 *              This class touches no data and needs no sharing declaration.
 */
public class AgentGovException extends Exception {
    public enum ErrorCode {
        FRAMEWORK_DISABLED,
        AGENT_NOT_FOUND,
        AGENT_NOT_ACTIVE,
        AGENT_BLOCKED,
        ACCESS_DENIED,
        BUDGET_EXCEEDED,
        BUDGET_THROTTLED,
        CIRCUIT_BREAKER_OPEN,
        POLICY_VIOLATION,
        RECORD_LOCKED,
        MAX_CONCURRENT_AGENTS,
        INVALID_INPUT,
        INTERNAL_ERROR
    }

    private ErrorCode code;

    /**
     * @description Creates an exception with a classified error code.
     * @param code The error classification
     * @param message Human-readable message safe to return to callers
     */
    public AgentGovException(ErrorCode code, String message) {
        this(message);
        this.code = code;
    }

    /**
     * @description Returns the error classification.
     * @return The error code, or null when the exception was created without one
     */
    public ErrorCode getErrorCode() {
        return this.code;
    }

    /**
     * @description Maps the error code to the HTTP status returned by the REST endpoints.
     * @return HTTP status code
     */
    public Integer getHttpStatusCode() {
        switch on this.code {
            when FRAMEWORK_DISABLED, CIRCUIT_BREAKER_OPEN {
                return 503;
            }
            when AGENT_NOT_FOUND {
                return 404;
            }
            when AGENT_NOT_ACTIVE, AGENT_BLOCKED, ACCESS_DENIED, POLICY_VIOLATION {
                return 403;
            }
            when BUDGET_EXCEEDED, BUDGET_THROTTLED, MAX_CONCURRENT_AGENTS {
                return 429;
            }
            when RECORD_LOCKED {
                return 409;
            }
            when INVALID_INPUT {
                return 400;
            }
            when else {
                return 500;
            }
        }
    }
}
