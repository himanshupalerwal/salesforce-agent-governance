/**
 * @description Custom exception class for the AgentGov framework.
 *              Provides typed exceptions with error codes for structured error handling.
 * @author Himanshu Palerwal
 */
public class AgentGovException extends Exception {

    public enum ErrorCode {
        FRAMEWORK_DISABLED,
        AGENT_NOT_FOUND,
        AGENT_NOT_ACTIVE,
        AGENT_BLOCKED,
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

    public AgentGovException(ErrorCode code, String message) {
        this(message);
        this.code = code;
    }

    public ErrorCode getErrorCode() {
        return this.code;
    }

    public Integer getHttpStatusCode() {
        switch on this.code {
            when FRAMEWORK_DISABLED {
                return 503;
            }
            when AGENT_NOT_FOUND {
                return 404;
            }
            when AGENT_NOT_ACTIVE, AGENT_BLOCKED {
                return 403;
            }
            when BUDGET_EXCEEDED, BUDGET_THROTTLED {
                return 429;
            }
            when CIRCUIT_BREAKER_OPEN {
                return 503;
            }
            when POLICY_VIOLATION {
                return 403;
            }
            when RECORD_LOCKED {
                return 409;
            }
            when MAX_CONCURRENT_AGENTS {
                return 429;
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
