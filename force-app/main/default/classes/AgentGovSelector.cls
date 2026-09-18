/**
 * @description Centralized data access for the framework's own records.
 *
 *              Security posture: without sharing, and every query runs WITH SYSTEM_MODE.
 *              The framework must be able to read its registrations, budgets, policies, and
 *              limit configuration regardless of who triggered the governed action; an
 *              Agentforce Agent User or an integration user typically has no access to
 *              AgentGov objects at all. Custom metadata is included on purpose: if policy
 *              records were read in user mode, a caller without field access would see
 *              blank policies and the policy engine would fall through to its default-allow
 *              path. Data that is presented to people in the dashboard is read through
 *              AgentGovDashboardController in user mode instead.
 *
 *              Frequently used records are cached for the duration of the transaction.
 */
@SuppressWarnings('PMD.ApexSharingViolations')
public without sharing class AgentGovSelector {
    // Static caches to minimize SOQL usage per transaction
    private static AgentGov_Settings__c cachedSettings;
    private static List<AgentGov_Limit_Config__mdt> cachedLimitConfigs;
    private static List<AgentGov_Policy__mdt> cachedPolicies;
    private static Map<Id, AgentGov_Registration__c> cachedRegistrations = new Map<Id, AgentGov_Registration__c>();

    /** @description Retrieves the org-level AgentGov settings, with defaults when none are configured. Cached per transaction. */
    public static AgentGov_Settings__c getSettings() {
        if (cachedSettings == null) {
            cachedSettings = AgentGov_Settings__c.getOrgDefaults();
            if (cachedSettings == null || cachedSettings.Id == null) {
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

    /** @description Checks whether the framework is enabled. An unset flag counts as enabled. */
    public static Boolean isFrameworkEnabled() {
        return getSettings().Is_Enabled__c != false;
    }

    /** @description Checks whether platform-event publishing is enabled. An unset flag counts as enabled. */
    public static Boolean isRealTimeEventsEnabled() {
        return getSettings().Enable_Real_Time_Events__c != false;
    }

    /** @description Retrieves all active limit configurations. Cached per transaction. */
    public static List<AgentGov_Limit_Config__mdt> getLimitConfigs() {
        if (cachedLimitConfigs == null) {
            cachedLimitConfigs = [
                SELECT
                    MasterLabel,
                    DeveloperName,
                    Limit_Type__c,
                    Warning_Threshold__c,
                    Throttle_Threshold__c,
                    Block_Threshold__c,
                    Default_Daily_Budget__c,
                    Is_Active__c
                FROM AgentGov_Limit_Config__mdt
                WHERE Is_Active__c = TRUE
                WITH SYSTEM_MODE
            ];
        }
        return cachedLimitConfigs;
    }

    /** @description Gets the limit configuration for a specific limit type, or null when none is defined. */
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
                SELECT
                    MasterLabel,
                    DeveloperName,
                    Agent_Type__c,
                    Object_Name__c,
                    Operation__c,
                    Is_Allowed__c,
                    Field_Restrictions__c,
                    Max_Records_Per_Transaction__c,
                    Description__c
                FROM AgentGov_Policy__mdt
                WITH SYSTEM_MODE
            ];
        }
        return cachedPolicies;
    }

    /** @description Gets the policies that apply to an agent type, including policies for all types. */
    public static List<AgentGov_Policy__mdt> getPoliciesForAgentType(String agentType) {
        List<AgentGov_Policy__mdt> applicable = new List<AgentGov_Policy__mdt>();
        for (AgentGov_Policy__mdt policy : getPolicies()) {
            if (policy.Agent_Type__c == agentType || policy.Agent_Type__c == AgentGovConstants.POLICY_ALL) {
                applicable.add(policy);
            }
        }
        return applicable;
    }

    /** @description Retrieves an agent registration by Id. Cached per transaction. */
    public static AgentGov_Registration__c getRegistrationById(Id registrationId) {
        if (registrationId == null) {
            return null;
        }
        if (!cachedRegistrations.containsKey(registrationId)) {
            getRegistrationsByIds(new Set<Id>{ registrationId });
        }
        return cachedRegistrations.get(registrationId);
    }

    /**
     * @description Retrieves registrations by Id in one query and seeds the cache.
     * @param registrationIds Ids to load
     * @return Map of Id to registration for every Id that exists
     */
    public static Map<Id, AgentGov_Registration__c> getRegistrationsByIds(Set<Id> registrationIds) {
        Map<Id, AgentGov_Registration__c> found = new Map<Id, AgentGov_Registration__c>();
        Set<Id> toQuery = new Set<Id>();
        for (Id registrationId : registrationIds) {
            if (registrationId == null) {
                continue;
            }
            if (cachedRegistrations.containsKey(registrationId)) {
                found.put(registrationId, cachedRegistrations.get(registrationId));
            } else {
                toQuery.add(registrationId);
            }
        }
        if (!toQuery.isEmpty()) {
            for (AgentGov_Registration__c reg : [
                SELECT
                    Id,
                    Name,
                    Agent_Name__c,
                    Agent_Type__c,
                    Status__c,
                    Owner_Email__c,
                    Description__c,
                    API_Key__c,
                    API_Key_Hash__c,
                    API_Key_Prefix__c,
                    API_Key_Last_Rotated__c,
                    Agent_User__c,
                    Priority__c,
                    Daily_API_Budget__c,
                    Daily_SOQL_Budget__c,
                    Daily_DML_Budget__c,
                    Last_Active__c,
                    Circuit_Breaker_State__c,
                    Failure_Count__c,
                    Last_Failure__c,
                    Cooldown_Until__c,
                    Half_Open_Probe_At__c
                FROM AgentGov_Registration__c
                WHERE Id IN :toQuery
                WITH SYSTEM_MODE
            ]) {
                cachedRegistrations.put(reg.Id, reg);
                found.put(reg.Id, reg);
            }
        }
        return found;
    }

    /**
     * @description Re-reads registrations with a row lock so that circuit-breaker state
     *              transitions are serialized across concurrent transactions.
     * @param registrationIds Ids to lock
     * @return Map of Id to freshly read registration
     */
    public static Map<Id, AgentGov_Registration__c> getRegistrationsForUpdate(Set<Id> registrationIds) {
        Map<Id, AgentGov_Registration__c> locked = new Map<Id, AgentGov_Registration__c>();
        if (registrationIds == null || registrationIds.isEmpty()) {
            return locked;
        }
        for (AgentGov_Registration__c reg : [
            SELECT
                Id,
                Name,
                Agent_Name__c,
                Agent_Type__c,
                Status__c,
                Owner_Email__c,
                Description__c,
                API_Key__c,
                API_Key_Hash__c,
                API_Key_Prefix__c,
                API_Key_Last_Rotated__c,
                Agent_User__c,
                Priority__c,
                Daily_API_Budget__c,
                Daily_SOQL_Budget__c,
                Daily_DML_Budget__c,
                Last_Active__c,
                Circuit_Breaker_State__c,
                Failure_Count__c,
                Last_Failure__c,
                Cooldown_Until__c,
                Half_Open_Probe_At__c
            FROM AgentGov_Registration__c
            WHERE Id IN :registrationIds
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            cachedRegistrations.put(reg.Id, reg);
            locked.put(reg.Id, reg);
        }
        return locked;
    }

    /** @description Retrieves a registration by the SHA-256 hash of its API key. */
    public static AgentGov_Registration__c getRegistrationByApiKeyHash(String apiKeyHash) {
        if (String.isBlank(apiKeyHash)) {
            return null;
        }
        List<AgentGov_Registration__c> registrations = [
            SELECT Id
            FROM AgentGov_Registration__c
            WHERE API_Key_Hash__c = :apiKeyHash
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return registrations.isEmpty() ? null : getRegistrationById(registrations[0].Id);
    }

    /**
     * @description Retrieves a registration by a plaintext API key stored by releases
     *              before v1.2. Used only to upgrade such keys to hashed storage on first use.
     * @param apiKey Plaintext key as presented by the caller
     * @return The registration, or null
     */
    public static AgentGov_Registration__c getRegistrationByLegacyApiKey(String apiKey) {
        if (String.isBlank(apiKey)) {
            return null;
        }
        List<AgentGov_Registration__c> registrations = [
            SELECT Id
            FROM AgentGov_Registration__c
            WHERE API_Key__c = :apiKey
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return registrations.isEmpty() ? null : getRegistrationById(registrations[0].Id);
    }

    /** @description Retrieves the registration bound to a user, or null when the user is not an agent. */
    public static AgentGov_Registration__c getRegistrationByAgentUser(Id userId) {
        if (userId == null) {
            return null;
        }
        List<AgentGov_Registration__c> registrations = [
            SELECT Id
            FROM AgentGov_Registration__c
            WHERE Agent_User__c = :userId
            WITH SYSTEM_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        return registrations.isEmpty() ? null : getRegistrationById(registrations[0].Id);
    }

    /** @description Replaces the cached copy of a registration after the framework updates it. */
    public static void cacheRegistration(AgentGov_Registration__c registration) {
        if (registration != null && registration.Id != null) {
            cachedRegistrations.put(registration.Id, registration);
        }
    }

    /** @description Retrieves all registrations in Active status. */
    public static List<AgentGov_Registration__c> getActiveRegistrations() {
        return [
            SELECT
                Id,
                Name,
                Agent_Name__c,
                Agent_Type__c,
                Status__c,
                Owner_Email__c,
                Priority__c,
                Daily_API_Budget__c,
                Daily_SOQL_Budget__c,
                Daily_DML_Budget__c,
                Last_Active__c,
                Circuit_Breaker_State__c,
                Failure_Count__c,
                Last_Failure__c,
                Cooldown_Until__c
            FROM AgentGov_Registration__c
            WHERE Status__c = :AgentGovConstants.STATUS_ACTIVE
            WITH SYSTEM_MODE
        ];
    }

    /** @description Counts registrations in Active status. */
    public static Integer getActiveAgentCount() {
        return [
            SELECT COUNT()
            FROM AgentGov_Registration__c
            WHERE Status__c = :AgentGovConstants.STATUS_ACTIVE
            WITH SYSTEM_MODE
        ];
    }

    /** @description Retrieves registrations whose breaker is OPEN and whose cooldown has elapsed. */
    public static List<AgentGov_Registration__c> getOpenAgentsPastCooldown() {
        DateTime now = DateTime.now();
        return [
            SELECT
                Id,
                Agent_Name__c,
                Circuit_Breaker_State__c,
                Failure_Count__c,
                Cooldown_Until__c,
                Half_Open_Probe_At__c,
                Status__c
            FROM AgentGov_Registration__c
            WHERE Circuit_Breaker_State__c = :AgentGovConstants.CB_OPEN AND Cooldown_Until__c <= :now
            WITH SYSTEM_MODE
        ];
    }

    /**
     * @description Reads today's budgets for a set of agents with a row lock, so that
     *              concurrent consumption is serialized per budget row.
     * @param registrationIds Agents whose budgets to lock
     * @return Map of registration Id to today's budget for each agent that has one
     */
    public static Map<Id, AgentGov_Budget__c> getTodaysBudgetsForUpdate(Set<Id> registrationIds) {
        Map<Id, AgentGov_Budget__c> budgets = new Map<Id, AgentGov_Budget__c>();
        if (registrationIds == null || registrationIds.isEmpty()) {
            return budgets;
        }
        Date today = Date.today();
        for (AgentGov_Budget__c budget : [
            SELECT
                Id,
                Agent_Registration__c,
                Budget_Date__c,
                Budget_Key__c,
                API_Calls_Allocated__c,
                API_Calls_Consumed__c,
                SOQL_Queries_Allocated__c,
                SOQL_Queries_Consumed__c,
                DML_Operations_Allocated__c,
                DML_Operations_Consumed__c,
                Budget_Status__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c IN :registrationIds AND Budget_Date__c = :today
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            budgets.put(budget.Agent_Registration__c, budget);
        }
        return budgets;
    }

    /** @description Reads today's budget for one agent with a row lock, or null when none exists. */
    public static AgentGov_Budget__c getTodaysBudgetForUpdate(Id registrationId) {
        return getTodaysBudgetsForUpdate(new Set<Id>{ registrationId }).get(registrationId);
    }

    /**
     * @description Reads today's budgets for a set of agents without a lock.
     * @param registrationIds Agents whose budgets to read
     * @return Map of registration Id to today's budget for each agent that has one
     */
    public static Map<Id, AgentGov_Budget__c> getTodaysBudgets(Set<Id> registrationIds) {
        Map<Id, AgentGov_Budget__c> budgets = new Map<Id, AgentGov_Budget__c>();
        if (registrationIds == null || registrationIds.isEmpty()) {
            return budgets;
        }
        Date today = Date.today();
        for (AgentGov_Budget__c budget : [
            SELECT
                Id,
                Agent_Registration__c,
                Budget_Date__c,
                Budget_Key__c,
                API_Calls_Allocated__c,
                API_Calls_Consumed__c,
                SOQL_Queries_Allocated__c,
                SOQL_Queries_Consumed__c,
                DML_Operations_Allocated__c,
                DML_Operations_Consumed__c,
                Budget_Status__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c IN :registrationIds AND Budget_Date__c = :today
            WITH SYSTEM_MODE
        ]) {
            budgets.put(budget.Agent_Registration__c, budget);
        }
        return budgets;
    }

    /** @description Reads today's budget for one agent without a lock, or null when none exists. */
    public static AgentGov_Budget__c getTodaysBudget(Id registrationId) {
        return getTodaysBudgets(new Set<Id>{ registrationId }).get(registrationId);
    }

    /**
     * @description Reads the most recent active session for each of a set of agents.
     * @param registrationIds Agents whose sessions to read
     * @return Map of registration Id to its newest active session
     */
    public static Map<Id, AgentGov_Session__c> getActiveSessionsByAgent(Set<Id> registrationIds) {
        Map<Id, AgentGov_Session__c> sessions = new Map<Id, AgentGov_Session__c>();
        if (registrationIds == null || registrationIds.isEmpty()) {
            return sessions;
        }
        for (AgentGov_Session__c session : [
            SELECT
                Id,
                Agent_Registration__c,
                Session_Start__c,
                Session_End__c,
                Status__c,
                API_Calls_Used__c,
                SOQL_Queries_Used__c,
                DML_Statements_Used__c,
                Actions_Count__c
            FROM AgentGov_Session__c
            WHERE Agent_Registration__c IN :registrationIds AND Status__c = :AgentGovConstants.SESSION_ACTIVE
            WITH SYSTEM_MODE
            ORDER BY Session_Start__c DESC
        ]) {
            if (!sessions.containsKey(session.Agent_Registration__c)) {
                sessions.put(session.Agent_Registration__c, session);
            }
        }
        return sessions;
    }

    /** @description Reads the most recent active session for an agent, or null. */
    public static AgentGov_Session__c getActiveSession(Id registrationId) {
        return getActiveSessionsByAgent(new Set<Id>{ registrationId }).get(registrationId);
    }

    /** @description Reads a session by Id, or null when it does not exist. */
    public static AgentGov_Session__c getSessionById(Id sessionId) {
        if (sessionId == null) {
            return null;
        }
        List<AgentGov_Session__c> sessions = [
            SELECT
                Id,
                Agent_Registration__c,
                Status__c,
                Session_Start__c,
                Session_End__c,
                API_Calls_Used__c,
                SOQL_Queries_Used__c,
                DML_Statements_Used__c,
                Actions_Count__c
            FROM AgentGov_Session__c
            WHERE Id = :sessionId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return sessions.isEmpty() ? null : sessions[0];
    }

    /** @description Reads sessions that have been active longer than the given number of hours. */
    public static List<AgentGov_Session__c> getOrphanedSessions(Integer maxHours) {
        DateTime cutoff = DateTime.now().addHours(-maxHours);
        return [
            SELECT Id, Agent_Registration__c, Session_Start__c, Status__c
            FROM AgentGov_Session__c
            WHERE Status__c = :AgentGovConstants.SESSION_ACTIVE AND Session_Start__c < :cutoff
            WITH SYSTEM_MODE
        ];
    }

    /** @description Reads the most recent action logs for an agent. */
    public static List<AgentGov_Action_Log__c> getRecentActionLogs(Id registrationId, Integer limitCount) {
        return [
            SELECT
                Id,
                Agent_Registration__c,
                Action_Type__c,
                Object_Name__c,
                Record_Id__c,
                Status__c,
                Error_Message__c,
                Execution_Time_Ms__c,
                Timestamp__c,
                Details__c
            FROM AgentGov_Action_Log__c
            WHERE Agent_Registration__c = :registrationId
            WITH SYSTEM_MODE
            ORDER BY Timestamp__c DESC
            LIMIT :limitCount
        ];
    }

    /** @description Clears all transaction caches. Intended for tests and for code that changes settings mid-transaction. */
    @TestVisible
    public static void clearCache() {
        cachedSettings = null;
        cachedLimitConfigs = null;
        cachedPolicies = null;
        cachedRegistrations.clear();
    }
}
