/**
 * @description Constants and string literals for the AgentGov framework.
 *              Centralizes picklist values, default thresholds, REST contract strings,
 *              and error messages so that every layer speaks the same vocabulary.
 *              This class touches no data and needs no sharing declaration.
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

    // Budget Status, in escalation order. BUDGET_STATUS_RANK is used to decide
    // whether a consumption moved the budget to a more severe state.
    public static final String BUDGET_NORMAL = 'Normal';
    public static final String BUDGET_WARNING = 'Warning';
    public static final String BUDGET_THROTTLED = 'Throttled';
    public static final String BUDGET_BLOCKED = 'Blocked';
    public static final String BUDGET_EXHAUSTED = 'Exhausted';

    /**
     * @description Reported instead of a budget status when Is_Enabled__c is off. It is not a
     *              value of the Budget Status picklist: no budget was evaluated, because
     *              enforcement was bypassed.
     */
    public static final String BUDGET_BYPASSED = 'Bypassed';
    public static final Map<String, Integer> BUDGET_STATUS_RANK = new Map<String, Integer>{
        BUDGET_NORMAL => 0,
        BUDGET_WARNING => 1,
        BUDGET_THROTTLED => 2,
        BUDGET_BLOCKED => 3,
        BUDGET_EXHAUSTED => 4
    };

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
    public static final String ACTION_REPORT = 'Report';
    // Used for audit rows the framework writes about itself: purge summaries,
    // delivery failures, and unhandled REST errors.
    public static final String ACTION_SYSTEM = 'System';

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
    public static final String ALERT_LIMIT_CIRCUIT_BREAKER = 'Circuit_Breaker';

    // Limit Types
    public static final String LIMIT_API_CALLS = 'API_Calls';
    public static final String LIMIT_SOQL_QUERIES = 'SOQL_Queries';
    public static final String LIMIT_DML_OPERATIONS = 'DML_Operations';
    public static final Set<String> VALID_LIMIT_TYPES = new Set<String>{
        LIMIT_API_CALLS,
        LIMIT_SOQL_QUERIES,
        LIMIT_DML_OPERATIONS
    };

    // Default Thresholds (percent of the daily allocation)
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

    // Circuit breaker behavior
    // A re-tripped breaker doubles its cooldown, capped at one day so a flapping
    // agent is never locked out for an unbounded period.
    public static final Integer CB_RETRY_COOLDOWN_MULTIPLIER = 2;
    public static final Integer CB_MAX_COOLDOWN_MINUTES = 1440;
    // Sessions still active after this many hours are closed by the health check.
    public static final Integer ORPHAN_SESSION_HOURS = 24;

    // Policy Wildcards
    public static final String POLICY_ALL = 'All';
    public static final String POLICY_WILDCARD = '*';

    // REST API contract
    public static final String REST_BASE_PATH = '/agentgov/';
    public static final String REST_PROXY_BASE_PATH = '/agentgov-proxy/';
    public static final String REST_HEADER_API_KEY = 'X-AgentGov-Key';
    public static final String REST_HEADER_API_KEY_LEGACY = 'X-AgentGov-API-Key';
    public static final String REST_HEADER_CORRELATION_ID = 'X-Correlation-Id';
    public static final String REST_BODY_API_KEY = 'apiKey';
    public static final String REST_DEPRECATION_BODY_KEY = 'Passing apiKey in the request body is deprecated and will be removed in v1.3. Send it in the X-AgentGov-Key header instead.';

    // API keys are 256 random bits rendered as hex behind a recognizable prefix.
    // The prefix field keeps the first characters so admins can identify a key
    // without the framework ever storing the key itself.
    public static final String API_KEY_PREFIX = 'agk_';
    public static final Integer API_KEY_IDENTIFIER_LENGTH = 12;

    /**
     * @description Shortest key a caller may supply. The stored prefix is the first
     *              API_KEY_IDENTIFIER_LENGTH characters, so anything at or below that length
     *              would place the whole secret in a readable field. Generated keys are far
     *              longer; this only constrains caller-chosen keys.
     */
    public static final Integer API_KEY_MINIMUM_LENGTH = 24;
    public static final String API_KEY_HASH_ALGORITHM = 'SHA-256';

    // Custom permission that grants read access to any agent's budget and health
    // through the REST API, beyond the caller's own registration.
    public static final String CUSTOM_PERMISSION_ADMIN_ACCESS = 'AgentGov_Admin_Access';

    // Structured query defaults for the proxy /query endpoint
    public static final Integer DEFAULT_QUERY_LIMIT = 200;
    public static final Integer MAX_QUERY_LIMIT = 2000;
    public static final Set<String> QUERY_OPERATORS = new Set<String>{
        '=',
        '!=',
        '<',
        '<=',
        '>',
        '>=',
        'LIKE',
        'IN',
        'NOT IN'
    };

    // Name used on framework-generated audit entries that have no agent
    public static final String FRAMEWORK_ACTOR_NAME = 'AgentGov Framework';
    public static final String UNKNOWN_AGENT_NAME = 'Unknown';

    // Error Messages
    public static final String ERR_AGENT_NOT_FOUND = 'Agent registration not found.';
    public static final String ERR_AGENT_NOT_REGISTERED = 'Agent not registered. Call /register first.';
    public static final String ERR_AGENT_NOT_ACTIVE = 'Agent is not in Active status.';
    public static final String ERR_AUTH_REQUIRED = 'Authentication required. Send the agent API key in the X-AgentGov-Key header, or bind the running user to a registration.';
    public static final String ERR_ADMIN_ACCESS_REQUIRED = 'Access denied. Only the agent itself or a user with the AgentGov_Admin_Access custom permission can read this resource.';
    public static final String ERR_BUDGET_EXCEEDED = 'Governor budget exceeded for limit type: ';
    public static final String ERR_CIRCUIT_BREAKER_OPEN = 'Circuit breaker is OPEN. Agent is temporarily disabled.';
    public static final String ERR_POLICY_VIOLATION = 'Policy violation: Agent {0} is not authorized to {1} on {2}.';
    public static final String ERR_RESTRICTED_FIELDS = 'Policy violation: the following fields are restricted for this agent: ';
    public static final String ERR_MAX_RECORDS = 'Policy violation: this agent may process at most {0} records per transaction; {1} were submitted.';
    public static final String ERR_RECORD_LOCKED = 'Record is locked by another agent.';
    public static final String ERR_MAX_CONCURRENT_AGENTS = 'Maximum concurrent agent limit reached.';
    public static final String ERR_INVALID_AGENT_NAME = 'Agent name is required.';
    public static final String ERR_INVALID_AGENT_TYPE = 'Invalid agent type specified.';
    public static final String ERR_INVALID_LIMIT_TYPE = 'Invalid limit type: ';
    public static final String ERR_SESSION_NOT_ACTIVE = 'No active session found for this agent.';
    public static final String ERR_NULL_AGENT_ID = 'Agent registration ID cannot be null.';
    public static final String ERR_INVALID_OBJECT_NAME = 'Object name is required.';
    public static final String ERR_UNKNOWN_OBJECT = 'Unknown or inaccessible object: ';
    public static final String ERR_UNKNOWN_FIELD = 'Unknown field for {0}: {1}';
    public static final String ERR_INVALID_FIELD_NAME = 'Invalid field name: {0}. Only simple field API names are accepted; relationship paths and subqueries are not.';
    public static final String ERR_INVALID_OPERATOR = 'Unsupported operator: ';
    public static final String ERR_INVALID_ACTION_TYPE = 'Invalid action type: ';
    public static final String ERR_REGISTRATION_REJECTED = 'The registration could not be created with the values supplied.';
    public static final String ERR_INVALID_IN_VALUE = 'IN and NOT IN require a list of values for field: ';
    public static final String ERR_NO_RECORDS = 'At least one record is required.';
    public static final String ERR_NO_FIELDS = 'At least one field is required.';
    public static final String ERR_NO_IDS = 'At least one record Id is required.';
    public static final String ERR_RECORD_ID_REQUIRED = 'Every record must include an Id for this operation.';
    public static final String ERR_INVALID_RECORD_ID = 'Invalid record Id: ';
    public static final String ERR_ID_TYPE_MISMATCH = 'Record Id {0} does not belong to object {1}.';
    public static final String ERR_RAW_SOQL_UNSUPPORTED = 'Raw SOQL is no longer accepted by /query. Send objectName, fields, and optional where, orderBy, and limit instead. See docs/rest-api-reference.md.';
    public static final String ERR_FIELDS_NOT_ACCESSIBLE = 'The agent user is not permitted to {0} these fields on {1}: {2}';
    public static final String ERR_INTERNAL = 'Internal error. Quote the correlationId when reporting this problem.';
    public static final String ERR_ENDPOINT_NOT_FOUND = 'Endpoint not found: ';

    // Valid Agent Types Set (for validation)
    public static final Set<String> VALID_AGENT_TYPES = new Set<String>{
        AGENT_TYPE_AGENTFORCE,
        AGENT_TYPE_MCP_EXTERNAL,
        AGENT_TYPE_CUSTOM_APEX,
        AGENT_TYPE_FLOW_BASED
    };

    // Valid Operations Set
    public static final Set<String> VALID_OPERATIONS = new Set<String>{
        ACTION_QUERY,
        ACTION_CREATE,
        ACTION_UPDATE,
        ACTION_DELETE,
        ACTION_UPSERT,
        ACTION_API_CALL,
        ACTION_FLOW_TRIGGER
    };

    @SuppressWarnings('PMD.EmptyStatementBlock')
    private AgentGovConstants() {
        // A constants holder is never instantiated; the private constructor is what enforces it.
    }
}
