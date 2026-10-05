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
 *              path. Records presented to people on the dashboard and in the console are read
 *              in user mode through AgentGovDashboardController and AgentGovAdminController
 *              instead. The configuration the console shows, such as the settings, scheduled
 *              job status and policy problems on its setup checklist, is read here in system
 *              mode, behind the AgentGov_Operate_Agents permission the controller checks.
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
    private static String cachedOrgTimeZone;

    /**
     * @description Retrieves the org-level AgentGov settings, with defaults when none are
     *              configured. Cached per transaction.
     * @return The org defaults, or an unsaved record holding the framework defaults
     */
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
                cachedSettings.Session_Idle_Minutes__c = AgentGovConstants.DEFAULT_SESSION_IDLE_MINUTES;
                cachedSettings.Budget_Retention_Days__c = AgentGovConstants.DEFAULT_BUDGET_RETENTION_DAYS;
            }
        }
        return cachedSettings;
    }

    /**
     * @description Returns the org's default time zone. Budget days are counted in it, so an
     *              agent's day does not depend on which user's session made the call. Cached
     *              per transaction.
     * @return The time zone's Id, such as America/Los_Angeles
     */
    public static String getOrgTimeZone() {
        if (cachedOrgTimeZone == null) {
            cachedOrgTimeZone = [SELECT TimeZoneSidKey FROM Organization WITH SYSTEM_MODE LIMIT 1].TimeZoneSidKey;
        }
        return cachedOrgTimeZone;
    }

    /**
     * @description Checks whether the framework is enabled. An unset flag counts as enabled.
     * @return False only while Is_Enabled__c is unchecked
     */
    public static Boolean isFrameworkEnabled() {
        return getSettings().Is_Enabled__c != false;
    }

    /**
     * @description Checks whether platform-event publishing is enabled. An unset flag counts as
     *              enabled.
     * @return False only while Enable_Real_Time_Events__c is unchecked
     */
    public static Boolean isRealTimeEventsEnabled() {
        return getSettings().Enable_Real_Time_Events__c != false;
    }

    /**
     * @description Retrieves all active limit configurations. Cached per transaction.
     * @return The AgentGov_Limit_Config__mdt records with Is_Active__c checked
     */
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

    /**
     * @description Gets the active limit configuration for a limit type.
     * @param limitType One of the AgentGovConstants.LIMIT_* values
     * @return The configuration, or null when none is defined
     */
    public static AgentGov_Limit_Config__mdt getLimitConfigByType(String limitType) {
        for (AgentGov_Limit_Config__mdt config : getLimitConfigs()) {
            if (config.Limit_Type__c == limitType) {
                return config;
            }
        }
        return null;
    }

    /**
     * @description Retrieves all policies. Cached per transaction.
     * @return Every AgentGov_Policy__mdt record
     */
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

    /**
     * @description Gets the policies that apply to an agent type, including policies for all
     *              types. A policy may name the type by its stored value or by its label.
     * @param agentType The Agent_Type__c stored on a registration
     * @return The applicable policies
     */
    public static List<AgentGov_Policy__mdt> getPoliciesForAgentType(String agentType) {
        List<AgentGov_Policy__mdt> applicable = new List<AgentGov_Policy__mdt>();
        for (AgentGov_Policy__mdt policy : getPolicies()) {
            if (AgentGovPolicyEngine.appliesToAgentType(policy, agentType)) {
                applicable.add(policy);
            }
        }
        return applicable;
    }

    /**
     * @description Replaces the policies read from custom metadata for the rest of the
     *              transaction, so tests can evaluate policy records the org does not hold.
     * @param policies In-memory policy records
     */
    @TestVisible
    private static void usePolicies(List<AgentGov_Policy__mdt> policies) {
        cachedPolicies = policies;
    }

    /**
     * @description Retrieves an agent registration by Id. Cached per transaction.
     * @param registrationId The agent registration Id
     * @return The registration, or null when the Id is null or names none
     */
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
     * @description Re-reads registrations with a row lock so that changes to them, such as
     *              circuit-breaker transitions and activation or deactivation, are serialized
     *              across concurrent transactions.
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

    /**
     * @description Retrieves a registration by the SHA-256 hash of its API key.
     * @param apiKeyHash The hash in hex
     * @return The registration, or null when the hash is blank or matches none
     */
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

    /**
     * @description Retrieves the registration bound to a user. When the user is bound to
     *              several registrations this returns the most recently modified one;
     *              AgentGovRestAuth uses getRegistrationIdsByAgentUser instead so that it can
     *              refuse to guess.
     * @param userId The user to look up
     * @return The registration, or null when the user is not bound to one
     */
    public static AgentGov_Registration__c getRegistrationByAgentUser(Id userId) {
        List<Id> ids = getRegistrationIdsByAgentUser(userId);
        return ids.isEmpty() ? null : getRegistrationById(ids[0]);
    }

    /**
     * @description Returns the Ids of up to two registrations bound to a user, most recently
     *              modified first. Two are enough to tell a unique binding from an ambiguous one.
     * @param userId The user to look up
     * @return Zero, one or two registration Ids
     */
    public static List<Id> getRegistrationIdsByAgentUser(Id userId) {
        List<Id> ids = new List<Id>();
        if (userId == null) {
            return ids;
        }
        for (AgentGov_Registration__c registration : [
            SELECT Id
            FROM AgentGov_Registration__c
            WHERE Agent_User__c = :userId
            WITH SYSTEM_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 2
        ]) {
            ids.add(registration.Id);
        }
        return ids;
    }

    /**
     * @description Replaces the cached copy of a registration after the framework updates it.
     * @param registration The registration as written; ignored when it has no Id
     */
    public static void cacheRegistration(AgentGov_Registration__c registration) {
        if (registration != null && registration.Id != null) {
            cachedRegistrations.put(registration.Id, registration);
        }
    }

    /**
     * @description Retrieves all registrations in Active status.
     * @return The active registrations
     */
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

    /**
     * @description Counts registrations in Active status.
     * @return The number of active registrations
     */
    public static Integer getActiveAgentCount() {
        return [
            SELECT COUNT()
            FROM AgentGov_Registration__c
            WHERE Status__c = :AgentGovConstants.STATUS_ACTIVE
            WITH SYSTEM_MODE
        ];
    }

    /**
     * @description Retrieves registrations whose breaker is OPEN and whose cooldown has elapsed,
     *              without a lock.
     * @return The registrations due to move to HALF_OPEN
     */
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
        Date today = AgentGovBudgetManager.budgetDate();
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

    /**
     * @description Reads today's budget for one agent with a row lock.
     * @param registrationId The agent registration Id
     * @return Today's budget, or null when none exists
     */
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
        Date today = AgentGovBudgetManager.budgetDate();
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

    /**
     * @description Reads today's budget for one agent without a lock.
     * @param registrationId The agent registration Id
     * @return Today's budget, or null when none exists
     */
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
                Last_Activity__c,
                Status__c,
                End_Reason__c,
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

    /**
     * @description Reads the newest active session of each agent under a row lock, so two
     *              transactions adding usage to the same session cannot overwrite each other's
     *              counts. FOR UPDATE cannot be combined with ORDER BY, so the newest session is
     *              picked here rather than in the query.
     * @param registrationIds Agents whose sessions to lock
     * @return Map of registration Id to its newest active session
     */
    public static Map<Id, AgentGov_Session__c> getActiveSessionsForUpdate(Set<Id> registrationIds) {
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
                Last_Activity__c,
                Status__c,
                API_Calls_Used__c,
                SOQL_Queries_Used__c,
                DML_Statements_Used__c,
                Actions_Count__c
            FROM AgentGov_Session__c
            WHERE Agent_Registration__c IN :registrationIds AND Status__c = :AgentGovConstants.SESSION_ACTIVE
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            AgentGov_Session__c newest = sessions.get(session.Agent_Registration__c);
            if (newest == null || session.Session_Start__c > newest.Session_Start__c) {
                sessions.put(session.Agent_Registration__c, session);
            }
        }
        return sessions;
    }

    /**
     * @description Reads every active session of the given agents under a row lock. Used when
     *              an agent is deactivated, which must end all of its sessions, including any
     *              duplicates left by releases before v1.3, and when a caller starts a new
     *              session explicitly, which ends the agent's current ones first.
     * @param registrationIds Agents whose sessions to read
     * @return The active sessions
     */
    public static List<AgentGov_Session__c> getAllActiveSessionsForUpdate(Set<Id> registrationIds) {
        if (registrationIds == null || registrationIds.isEmpty()) {
            return new List<AgentGov_Session__c>();
        }
        return [
            SELECT Id, Agent_Registration__c, Session_Start__c, Last_Activity__c, Status__c
            FROM AgentGov_Session__c
            WHERE Agent_Registration__c IN :registrationIds AND Status__c = :AgentGovConstants.SESSION_ACTIVE
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
    }

    /**
     * @description Reads sessions by Id under a row lock.
     * @param sessionIds Sessions to read
     * @return Map of session Id to session
     */
    public static Map<Id, AgentGov_Session__c> getSessionsForUpdate(Set<Id> sessionIds) {
        if (sessionIds == null || sessionIds.isEmpty()) {
            return new Map<Id, AgentGov_Session__c>();
        }
        return new Map<Id, AgentGov_Session__c>(
            [
                SELECT Id, Agent_Registration__c, Session_Start__c, Last_Activity__c, Status__c
                FROM AgentGov_Session__c
                WHERE Id IN :sessionIds
                WITH SYSTEM_MODE
                FOR UPDATE
            ]
        );
    }

    /**
     * @description Reads active sessions that should be closed: idle since the cutoff, or
     *              started before the maximum-duration cutoff. A session with no recorded
     *              activity, which only releases before v1.3 created, is judged by its start.
     * @param idleCutoff Sessions last active before this are idle
     * @param maxStartCutoff Sessions started before this have run too long
     * @param maxRows Most rows to return
     * @return The sessions to close
     */
    public static List<AgentGov_Session__c> getStaleSessions(
        DateTime idleCutoff,
        DateTime maxStartCutoff,
        Integer maxRows
    ) {
        return [
            SELECT Id, Agent_Registration__c, Session_Start__c, Last_Activity__c, Status__c
            FROM AgentGov_Session__c
            WHERE
                Status__c = :AgentGovConstants.SESSION_ACTIVE
                AND (Last_Activity__c < :idleCutoff
                OR (Last_Activity__c = NULL
                AND Session_Start__c < :idleCutoff)
                OR Session_Start__c < :maxStartCutoff)
            WITH SYSTEM_MODE
            LIMIT :maxRows
        ];
    }

    /**
     * @description Reads the most recent active session for an agent.
     * @param registrationId The agent registration Id
     * @return The session, or null when the agent has no active session
     */
    public static AgentGov_Session__c getActiveSession(Id registrationId) {
        return getActiveSessionsByAgent(new Set<Id>{ registrationId }).get(registrationId);
    }

    /**
     * @description Reads a session by Id.
     * @param sessionId The session Id
     * @return The session, or null when the Id is null or names none
     */
    public static AgentGov_Session__c getSessionById(Id sessionId) {
        if (sessionId == null) {
            return null;
        }
        List<AgentGov_Session__c> sessions = [
            SELECT
                Id,
                Agent_Registration__c,
                Status__c,
                End_Reason__c,
                Session_Start__c,
                Session_End__c,
                Last_Activity__c,
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

    /**
     * @description Reads sessions that have been active longer than the given number of hours.
     *              Kept for callers written against v1.2; the health check uses getStaleSessions.
     * @param maxHours Sessions started more than this many hours ago are returned
     * @return The active sessions older than the cutoff
     */
    public static List<AgentGov_Session__c> getOrphanedSessions(Integer maxHours) {
        DateTime cutoff = DateTime.now().addHours(-maxHours);
        return [
            SELECT Id, Agent_Registration__c, Session_Start__c, Status__c
            FROM AgentGov_Session__c
            WHERE Status__c = :AgentGovConstants.SESSION_ACTIVE AND Session_Start__c < :cutoff
            WITH SYSTEM_MODE
        ];
    }

    /**
     * @description Reads scheduled jobs by name, with their schedule and next run.
     * @param jobNames Job names to look up
     * @return The matching scheduled jobs
     */
    public static List<CronTrigger> getScheduledJobs(List<String> jobNames) {
        return [
            SELECT Id, CronJobDetail.Name, CronExpression, NextFireTime, State
            FROM CronTrigger
            WHERE CronJobDetail.Name IN :jobNames
            WITH SYSTEM_MODE
        ];
    }

    /**
     * @description Reads the most recent action logs for an agent.
     * @param registrationId The agent registration Id
     * @param limitCount Most rows to return
     * @return The agent's rows, newest first
     */
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
                Correlation_Id__c,
                Agent_Session__c,
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
        cachedOrgTimeZone = null;
        cachedRegistrations.clear();
    }
}
