/**
 * @description Centralized data access layer for the AgentGov framework.
 *              All SOQL queries are routed through this class to ensure security,
 *              bulkification, and caching of frequently accessed data.
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovSelector {

    // Static caches to minimize SOQL usage per transaction
    private static AgentGov_Settings__c cachedSettings;
    private static List<AgentGov_Limit_Config__mdt> cachedLimitConfigs;
    private static List<AgentGov_Policy__mdt> cachedPolicies;
    private static Map<Id, AgentGov_Registration__c> cachedRegistrations = new Map<Id, AgentGov_Registration__c>();

    /** @description Retrieves the org-level AgentGov settings. Cached per transaction. */
    public static AgentGov_Settings__c getSettings() {
        if (cachedSettings == null) {
            cachedSettings = AgentGov_Settings__c.getOrgDefaults();
            if (cachedSettings == null) {
                cachedSettings = new AgentGov_Settings__c();
                cachedSettings.Is_Enabled__c = true;
                cachedSettings.Default_Agent_Priority__c = AgentGovConstants.DEFAULT_AGENT_PRIORITY;
                cachedSettings.Circuit_Breaker_Failure_Threshold__c = AgentGovConstants.DEFAULT_CB_FAILURE_THRESHOLD;
                cachedSettings.Circuit_Breaker_Cooldown_Minutes__c = AgentGovConstants.DEFAULT_CB_COOLDOWN_MINUTES;
                cachedSettings.Log_Retention_Days__c = AgentGovConstants.DEFAULT_LOG_RETENTION_DAYS;
                cachedSettings.Enable_Conflict_Detection__c = true;
                cachedSettings.Enable_Real_Time_Events__c = true;
                cachedSettings.Max_Concurrent_Agents__c = AgentGovConstants.DEFAULT_MAX_CONCURRENT_AGENTS;
            }
        }
        return cachedSettings;
    }

    /** @description Checks if the framework is enabled. */
    public static Boolean isFrameworkEnabled() {
        AgentGov_Settings__c settings = getSettings();
        return settings.Is_Enabled__c != false;
    }

    /** @description Retrieves all active limit configurations. Cached per transaction. */
    public static List<AgentGov_Limit_Config__mdt> getLimitConfigs() {
        if (cachedLimitConfigs == null) {
            cachedLimitConfigs = [
                SELECT MasterLabel, DeveloperName, Limit_Type__c, Warning_Threshold__c,
                       Throttle_Threshold__c, Block_Threshold__c, Default_Daily_Budget__c, Is_Active__c
                FROM AgentGov_Limit_Config__mdt
                WHERE Is_Active__c = true
            ];
        }
        return cachedLimitConfigs;
    }

    /** @description Gets limit config for a specific limit type. */
    public static AgentGov_Limit_Config__mdt getLimitConfigByType(String limitType) {
        for (AgentGov_Limit_Config__mdt config : getLimitConfigs()) {
            if (config.Limit_Type__c == limitType) {
                return config;
            }
        }
        return null;
    }

    /** @description Retrieves all policies. Cached per transaction. */
    public static List<AgentGov_Policy__mdt> getPolicies() {
        if (cachedPolicies == null) {
            cachedPolicies = [
                SELECT MasterLabel, DeveloperName, Agent_Type__c, Object_Name__c,
                       Operation__c, Is_Allowed__c, Field_Restrictions__c,
                       Max_Records_Per_Transaction__c, Description__c
                FROM AgentGov_Policy__mdt
            ];
        }
        return cachedPolicies;
    }

    /** @description Gets policies applicable to a specific agent type. */
    public static List<AgentGov_Policy__mdt> getPoliciesForAgentType(String agentType) {
        List<AgentGov_Policy__mdt> applicable = new List<AgentGov_Policy__mdt>();
        for (AgentGov_Policy__mdt policy : getPolicies()) {
            if (policy.Agent_Type__c == agentType || policy.Agent_Type__c == AgentGovConstants.POLICY_ALL) {
                applicable.add(policy);
            }
        }
        return applicable;
    }

    /** @description Retrieves an agent registration by ID. Cached. */
    public static AgentGov_Registration__c getRegistrationById(Id registrationId) {
        if (registrationId == null) {
            return null;
        }
        if (!cachedRegistrations.containsKey(registrationId)) {
            List<AgentGov_Registration__c> registrations = [
                SELECT Id, Name, Agent_Name__c, Agent_Type__c, Status__c, Owner_Email__c,
                       Description__c, API_Key__c, Priority__c, Daily_API_Budget__c,
                       Daily_SOQL_Budget__c, Daily_DML_Budget__c, Last_Active__c,
                       Circuit_Breaker_State__c, Failure_Count__c, Last_Failure__c,
                       Cooldown_Until__c
                FROM AgentGov_Registration__c
                WHERE Id = :registrationId
                WITH SECURITY_ENFORCED
                LIMIT 1
            ];
            if (!registrations.isEmpty()) {
                cachedRegistrations.put(registrationId, registrations[0]);
            }
        }
        return cachedRegistrations.get(registrationId);
    }

    /** @description Retrieves an agent registration by API Key. */
    public static AgentGov_Registration__c getRegistrationByApiKey(String apiKey) {
        if (String.isBlank(apiKey)) {
            return null;
        }
        List<AgentGov_Registration__c> registrations = [
            SELECT Id, Name, Agent_Name__c, Agent_Type__c, Status__c, Owner_Email__c,
                   Description__c, API_Key__c, Priority__c, Daily_API_Budget__c,
                   Daily_SOQL_Budget__c, Daily_DML_Budget__c, Last_Active__c,
                   Circuit_Breaker_State__c, Failure_Count__c, Last_Failure__c,
                   Cooldown_Until__c
            FROM AgentGov_Registration__c
            WHERE API_Key__c = :apiKey
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        if (!registrations.isEmpty()) {
            cachedRegistrations.put(registrations[0].Id, registrations[0]);
            return registrations[0];
        }
        return null;
    }

    /** @description Retrieves all active agent registrations. */
    @AuraEnabled(cacheable=true)
    public static List<AgentGov_Registration__c> getActiveRegistrations() {
        return [
            SELECT Id, Name, Agent_Name__c, Agent_Type__c, Status__c, Owner_Email__c,
                   Priority__c, Daily_API_Budget__c, Daily_SOQL_Budget__c, Daily_DML_Budget__c,
                   Last_Active__c, Circuit_Breaker_State__c, Failure_Count__c,
                   Last_Failure__c, Cooldown_Until__c
            FROM AgentGov_Registration__c
            WHERE Status__c = :AgentGovConstants.STATUS_ACTIVE
            WITH SECURITY_ENFORCED
        ];
    }

    /** @description Retrieves all registrations (any status). */
    @AuraEnabled(cacheable=true)
    public static List<AgentGov_Registration__c> getAllRegistrations() {
        return [
            SELECT Id, Name, Agent_Name__c, Agent_Type__c, Status__c, Owner_Email__c,
                   Priority__c, Daily_API_Budget__c, Daily_SOQL_Budget__c, Daily_DML_Budget__c,
                   Last_Active__c, Circuit_Breaker_State__c, Failure_Count__c,
                   Last_Failure__c, Cooldown_Until__c
            FROM AgentGov_Registration__c
            WITH SECURITY_ENFORCED
        ];
    }

    /** @description Gets today's budget for an agent. Uses FOR UPDATE for locking. */
    public static AgentGov_Budget__c getTodaysBudgetForUpdate(Id registrationId) {
        Date today = Date.today();
        List<AgentGov_Budget__c> budgets = [
            SELECT Id, Agent_Registration__c, Budget_Date__c,
                   API_Calls_Allocated__c, API_Calls_Consumed__c,
                   SOQL_Queries_Allocated__c, SOQL_Queries_Consumed__c,
                   DML_Operations_Allocated__c, DML_Operations_Consumed__c,
                   Budget_Status__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c = :registrationId
            AND Budget_Date__c = :today
            LIMIT 1
            FOR UPDATE
        ];
        return budgets.isEmpty() ? null : budgets[0];
    }

    /** @description Gets today's budget for an agent (read-only, no lock). */
    public static AgentGov_Budget__c getTodaysBudget(Id registrationId) {
        Date today = Date.today();
        List<AgentGov_Budget__c> budgets = [
            SELECT Id, Agent_Registration__c, Budget_Date__c,
                   API_Calls_Allocated__c, API_Calls_Consumed__c,
                   SOQL_Queries_Allocated__c, SOQL_Queries_Consumed__c,
                   DML_Operations_Allocated__c, DML_Operations_Consumed__c,
                   Budget_Status__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c = :registrationId
            AND Budget_Date__c = :today
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];
        return budgets.isEmpty() ? null : budgets[0];
    }

    /** @description Gets active session for an agent. */
    public static AgentGov_Session__c getActiveSession(Id registrationId) {
        List<AgentGov_Session__c> sessions = [
            SELECT Id, Agent_Registration__c, Session_Start__c, Session_End__c,
                   Status__c, API_Calls_Used__c, SOQL_Queries_Used__c,
                   DML_Statements_Used__c, Actions_Count__c
            FROM AgentGov_Session__c
            WHERE Agent_Registration__c = :registrationId
            AND Status__c = :AgentGovConstants.SESSION_ACTIVE
            WITH SECURITY_ENFORCED
            ORDER BY Session_Start__c DESC
            LIMIT 1
        ];
        return sessions.isEmpty() ? null : sessions[0];
    }

    /** @description Gets orphaned sessions (active longer than specified hours). */
    public static List<AgentGov_Session__c> getOrphanedSessions(Integer maxHours) {
        DateTime cutoff = DateTime.now().addHours(-maxHours);
        return [
            SELECT Id, Agent_Registration__c, Session_Start__c, Status__c
            FROM AgentGov_Session__c
            WHERE Status__c = :AgentGovConstants.SESSION_ACTIVE
            AND Session_Start__c < :cutoff
            WITH SECURITY_ENFORCED
        ];
    }

    /** @description Gets recent action logs for an agent. */
    public static List<AgentGov_Action_Log__c> getRecentActionLogs(Id registrationId, Integer limitCount) {
        return [
            SELECT Id, Agent_Registration__c, Action_Type__c, Object_Name__c,
                   Record_Id__c, Status__c, Error_Message__c, Execution_Time_Ms__c,
                   Timestamp__c, Details__c
            FROM AgentGov_Action_Log__c
            WHERE Agent_Registration__c = :registrationId
            ORDER BY Timestamp__c DESC
            LIMIT :limitCount
        ];
    }

    /** @description Gets recent conflict logs. */
    @AuraEnabled(cacheable=true)
    public static List<AgentGov_Conflict_Log__c> getRecentConflictLogs(Integer limitCount) {
        return [
            SELECT Id, Agent_1__c, Agent_2__c, Record_Id__c, Object_Name__c,
                   Conflict_Type__c, Resolution__c, Severity__c, Timestamp__c, Details__c,
                   Agent_1__r.Agent_Name__c, Agent_2__r.Agent_Name__c
            FROM AgentGov_Conflict_Log__c
            ORDER BY Timestamp__c DESC
            LIMIT :limitCount
        ];
    }

    /** @description Gets count of active agents. */
    public static Integer getActiveAgentCount() {
        return [
            SELECT COUNT()
            FROM AgentGov_Registration__c
            WHERE Status__c = :AgentGovConstants.STATUS_ACTIVE
            WITH SECURITY_ENFORCED
        ];
    }

    /** @description Gets all budgets for today (used by dashboard). */
    @AuraEnabled(cacheable=true)
    public static List<AgentGov_Budget__c> getAllTodaysBudgets() {
        Date today = Date.today();
        return [
            SELECT Id, Agent_Registration__c, Agent_Registration__r.Agent_Name__c,
                   Budget_Date__c, API_Calls_Allocated__c, API_Calls_Consumed__c,
                   SOQL_Queries_Allocated__c, SOQL_Queries_Consumed__c,
                   DML_Operations_Allocated__c, DML_Operations_Consumed__c,
                   Budget_Status__c
            FROM AgentGov_Budget__c
            WHERE Budget_Date__c = :today
            WITH SECURITY_ENFORCED
        ];
    }

    /** @description Gets registrations with HALF_OPEN circuit breaker past cooldown. */
    public static List<AgentGov_Registration__c> getHalfOpenAgentsPastCooldown() {
        DateTime now = DateTime.now();
        return [
            SELECT Id, Agent_Name__c, Circuit_Breaker_State__c, Failure_Count__c,
                   Cooldown_Until__c
            FROM AgentGov_Registration__c
            WHERE Circuit_Breaker_State__c = :AgentGovConstants.CB_HALF_OPEN
            AND Cooldown_Until__c <= :now
            WITH SECURITY_ENFORCED
        ];
    }

    /** @description Gets registrations with OPEN circuit breaker past cooldown (ready for HALF_OPEN). */
    public static List<AgentGov_Registration__c> getOpenAgentsPastCooldown() {
        DateTime now = DateTime.now();
        return [
            SELECT Id, Agent_Name__c, Circuit_Breaker_State__c, Failure_Count__c,
                   Cooldown_Until__c, Status__c
            FROM AgentGov_Registration__c
            WHERE Circuit_Breaker_State__c = :AgentGovConstants.CB_OPEN
            AND Cooldown_Until__c <= :now
            WITH SECURITY_ENFORCED
        ];
    }

    /** @description Clears all static caches. Useful in test context. */
    @TestVisible
    public static void clearCache() {
        cachedSettings = null;
        cachedLimitConfigs = null;
        cachedPolicies = null;
        cachedRegistrations.clear();
    }
}
