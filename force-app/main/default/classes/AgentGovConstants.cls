/**
 * @description Constants and string literals for the AgentGov framework.
 *              Centralizes all magic strings to ensure consistency and maintainability.
 * @author Himanshu Palerwal
 */
public class AgentGovConstants {

    // Agent Types
    public static final String AGENT_TYPE_AGENTFORCE = 'Agentforce';
    public static final String AGENT_TYPE_MCP_EXTERNAL = 'MCP_External';
    public static final String AGENT_TYPE_CUSTOM_APEX = 'Custom_Apex';
    public static final String AGENT_TYPE_FLOW_BASED = 'Flow_Based';

    // Agent Status
    public static final String STATUS_ACTIVE = 'Active';
    public static final String STATUS_INACTIVE = 'Inactive';
    public static final String STATUS_THROTTLED = 'Throttled';
    public static final String STATUS_BLOCKED = 'Blocked';

    // Session Status
    public static final String SESSION_ACTIVE = 'Active';
    public static final String SESSION_COMPLETED = 'Completed';
    public static final String SESSION_TERMINATED = 'Terminated';

    // Budget Status
    public static final String BUDGET_NORMAL = 'Normal';
    public static final String BUDGET_WARNING = 'Warning';
    public static final String BUDGET_THROTTLED = 'Throttled';
    public static final String BUDGET_BLOCKED = 'Blocked';
    public static final String BUDGET_EXHAUSTED = 'Exhausted';

    // Circuit Breaker States
    public static final String CB_CLOSED = 'CLOSED';
    public static final String CB_OPEN = 'OPEN';
    public static final String CB_HALF_OPEN = 'HALF_OPEN';

    // Action Types
    public static final String ACTION_QUERY = 'Query';
    public static final String ACTION_CREATE = 'Create';
    public static final String ACTION_UPDATE = 'Update';
    public static final String ACTION_DELETE = 'Delete';
    public static final String ACTION_UPSERT = 'Upsert';
    public static final String ACTION_API_CALL = 'API_Call';
    public static final String ACTION_FLOW_TRIGGER = 'Flow_Trigger';

    // Action Status
    public static final String ACTION_SUCCESS = 'Success';
    public static final String ACTION_FAILURE = 'Failure';
    public static final String ACTION_DENIED = 'Denied';
    public static final String ACTION_THROTTLED_STATUS = 'Throttled';

    // Conflict Types
    public static final String CONFLICT_CONCURRENT_WRITE = 'Concurrent_Write';
    public static final String CONFLICT_LOCK_CONTENTION = 'Lock_Contention';
    public static final String CONFLICT_PRIORITY_OVERRIDE = 'Priority_Override';

    // Conflict Resolutions
    public static final String RESOLUTION_AGENT1_WON = 'Agent1_Won';
    public static final String RESOLUTION_AGENT2_WON = 'Agent2_Won';
    public static final String RESOLUTION_QUEUED = 'Queued';
    public static final String RESOLUTION_FAILED = 'Failed';

    // Conflict Severity
    public static final String SEVERITY_HIGH = 'High';
    public static final String SEVERITY_MEDIUM = 'Medium';
    public static final String SEVERITY_LOW = 'Low';

    // Alert Types
    public static final String ALERT_WARNING = 'Warning';
    public static final String ALERT_THROTTLE = 'Throttle';
    public static final String ALERT_BLOCK = 'Block';

    // Limit Types
    public static final String LIMIT_API_CALLS = 'API_Calls';
    public static final String LIMIT_SOQL_QUERIES = 'SOQL_Queries';
    public static final String LIMIT_DML_OPERATIONS = 'DML_Operations';

    // Default Thresholds
    public static final Decimal DEFAULT_WARNING_THRESHOLD = 80;
    public static final Decimal DEFAULT_THROTTLE_THRESHOLD = 90;
    public static final Decimal DEFAULT_BLOCK_THRESHOLD = 95;

    // Default Settings
    public static final Integer DEFAULT_AGENT_PRIORITY = 5;
    public static final Integer DEFAULT_CB_FAILURE_THRESHOLD = 5;
    public static final Integer DEFAULT_CB_COOLDOWN_MINUTES = 30;
    public static final Integer DEFAULT_LOG_RETENTION_DAYS = 90;
    public static final Integer DEFAULT_MAX_CONCURRENT_AGENTS = 10;
    public static final Integer DEFAULT_API_BUDGET = 10000;
    public static final Integer DEFAULT_SOQL_BUDGET = 5000;
    public static final Integer DEFAULT_DML_BUDGET = 3000;

    // Policy Wildcards
    public static final String POLICY_ALL = 'All';
    public static final String POLICY_WILDCARD = '*';

    // Action Types (continued)
    public static final String ACTION_REPORT = 'Report';

    // REST API
    public static final String REST_BASE_PATH = '/agentgov/';
    public static final String REST_PROXY_BASE_PATH = '/agentgov-proxy/';
    public static final String REST_HEADER_API_KEY = 'X-AgentGov-API-Key';

    // Error Messages
    public static final String ERR_FRAMEWORK_DISABLED = 'AgentGov framework is currently disabled.';
    public static final String ERR_AGENT_NOT_FOUND = 'Agent registration not found.';
    public static final String ERR_AGENT_NOT_REGISTERED = 'Agent not registered. Call /register first.';
    public static final String ERR_AGENT_NOT_ACTIVE = 'Agent is not in Active status.';
    public static final String ERR_AGENT_BLOCKED = 'Agent is currently blocked.';
    public static final String ERR_BUDGET_EXCEEDED = 'Governor budget exceeded for limit type: ';
    public static final String ERR_BUDGET_THROTTLED = 'Agent is throttled. Reduce request rate for limit type: ';
    public static final String ERR_CIRCUIT_BREAKER_OPEN = 'Circuit breaker is OPEN. Agent is temporarily disabled.';
    public static final String ERR_POLICY_VIOLATION = 'Policy violation: Agent {0} is not authorized to {1} on {2}.';
    public static final String ERR_RECORD_LOCKED = 'Record is locked by another agent.';
    public static final String ERR_MAX_CONCURRENT_AGENTS = 'Maximum concurrent agent limit reached.';
    public static final String ERR_INVALID_AGENT_NAME = 'Agent name is required.';
    public static final String ERR_INVALID_AGENT_TYPE = 'Invalid agent type specified.';
    public static final String ERR_SESSION_NOT_ACTIVE = 'No active session found for this agent.';
    public static final String ERR_NULL_AGENT_ID = 'Agent registration ID cannot be null.';
    public static final String ERR_INVALID_OBJECT_NAME = 'Object name is required.';
    public static final String ERR_NO_RECORDS = 'At least one record is required.';
    public static final String ERR_INVALID_SOQL = 'Invalid or disallowed SOQL query.';

    // Valid Agent Types Set (for validation)
    public static final Set<String> VALID_AGENT_TYPES = new Set<String>{
        AGENT_TYPE_AGENTFORCE,
        AGENT_TYPE_MCP_EXTERNAL,
        AGENT_TYPE_CUSTOM_APEX,
        AGENT_TYPE_FLOW_BASED
    };

    // Valid Operations Set
    public static final Set<String> VALID_OPERATIONS = new Set<String>{
        ACTION_QUERY, ACTION_CREATE, ACTION_UPDATE, ACTION_DELETE,
        ACTION_UPSERT, ACTION_API_CALL, ACTION_FLOW_TRIGGER
    };

    private AgentGovConstants() {
        // Prevent instantiation
    }
}
