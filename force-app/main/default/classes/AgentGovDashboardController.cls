/**
 * @description Read-only Apex controller for the AgentGov Lightning Web Components.
 *
 *              Security posture: with sharing, and every query runs WITH USER_MODE.
 *              The dashboards present framework data to people, so they must show only
 *              what the viewing user is allowed to see. This is the opposite choice from
 *              AgentGovSelector, which reads on behalf of the framework itself.
 *
 *              Every method is cacheable so components can use @wire and refreshApex.
 */
public with sharing class AgentGovDashboardController {
    // Upper bounds on what one dashboard read returns, so a large org cannot exhaust heap or
    // render thousands of rows at once.
    private static final Integer MAX_AGENTS = 2000;
    private static final Integer MAX_SESSIONS = 200;
    private static final Integer MAX_LOG_PAGE = 200;
    private static final Integer DEFAULT_LOG_PAGE = 50;
    private static final Integer MAX_HISTORY_DAYS = 90;
    private static final Integer MAX_ALERTS = 100;
    private static final Integer MAX_CONFLICTS = 200;

    // Rows no agent's request writes: alerts, and administrators' changes from the console.
    // System rows are not among them, because they also record an agent's request whose action
    // type is not a recognised operation.
    private static final Set<String> NON_AGENT_ACTION_TYPES = new Set<String>{
        AgentGovConstants.ACTION_ALERT,
        AgentGovConstants.ACTION_ADMIN
    };

    /**
     * @description One row of the console's agent list: the agent, today's budget, and its live
     *              session. hasApiKey is true when the agent holds an API key, also one with no
     *              stored prefix.
     */
    public class AgentSummary {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String agentType;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String breakerState;
        @AuraEnabled
        public DateTime cooldownUntil;
        @AuraEnabled
        public Decimal failureCount;
        @AuraEnabled
        public Decimal priority;
        @AuraEnabled
        public DateTime lastActive;
        @AuraEnabled
        public String budgetStatus;
        @AuraEnabled
        public Decimal peakUsagePercent;
        @AuraEnabled
        public Decimal apiUsagePercent;
        @AuraEnabled
        public Decimal soqlUsagePercent;
        @AuraEnabled
        public Decimal dmlUsagePercent;
        @AuraEnabled
        public Id liveSessionId;
        @AuraEnabled
        public Decimal sessionActions;
        @AuraEnabled
        public String apiKeyPrefix;
        @AuraEnabled
        public DateTime apiKeyLastRotated;
        @AuraEnabled
        public Boolean hasApiKey;
        @AuraEnabled
        public Boolean boundToUser;
    }

    /** @description One page of the action log, newest first. */
    public class ActionLogPage {
        @AuraEnabled
        public List<AgentGov_Action_Log__c> rows;
        @AuraEnabled
        public Boolean hasMore;
    }

    /** @description One day of budget usage. */
    public class UsageDay {
        @AuraEnabled
        public Date day;
        @AuraEnabled
        public Decimal apiCalls;
        @AuraEnabled
        public Decimal soqlQueries;
        @AuraEnabled
        public Decimal dmlOperations;
        @AuraEnabled
        public Decimal peakUsagePercent;
        @AuraEnabled
        public String budgetStatus;
    }

    /**
     * @description Returns every agent registration the viewer can see, up to 2,000.
     * @return The registrations, by agent name
     */
    @AuraEnabled(cacheable=true)
    public static List<AgentGov_Registration__c> getAllRegistrations() {
        try {
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
                WITH USER_MODE
                ORDER BY Agent_Name__c
                LIMIT :MAX_AGENTS
            ];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * @description Returns today's budgets, by the org's calendar, with the owning agent's name.
     * @return Today's budget rows, by agent name, up to 2,000
     */
    @AuraEnabled(cacheable=true)
    public static List<AgentGov_Budget__c> getAllTodaysBudgets() {
        Date today = AgentGovBudgetManager.budgetDate();
        try {
            return [
                SELECT
                    Id,
                    Agent_Registration__c,
                    Agent_Registration__r.Agent_Name__c,
                    Budget_Date__c,
                    API_Calls_Allocated__c,
                    API_Calls_Consumed__c,
                    SOQL_Queries_Allocated__c,
                    SOQL_Queries_Consumed__c,
                    DML_Operations_Allocated__c,
                    DML_Operations_Consumed__c,
                    Budget_Status__c
                FROM AgentGov_Budget__c
                WHERE Budget_Date__c = :today
                WITH USER_MODE
                ORDER BY Agent_Registration__r.Agent_Name__c
                LIMIT :MAX_AGENTS
            ];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * @description Returns the most recent conflict logs.
     * @param limitCount Rows to return, at most 200
     * @return The conflicts, newest first
     */
    @AuraEnabled(cacheable=true)
    public static List<AgentGov_Conflict_Log__c> getRecentConflictLogs(Integer limitCount) {
        Integer rowLimit = limitCount == null || limitCount < 1 ? 50 : Math.min(limitCount, MAX_CONFLICTS);
        try {
            return [
                SELECT
                    Id,
                    Agent_1__c,
                    Agent_2__c,
                    Record_Id__c,
                    Object_Name__c,
                    Conflict_Type__c,
                    Resolution__c,
                    Severity__c,
                    Timestamp__c,
                    Details__c,
                    Agent_1__r.Agent_Name__c,
                    Agent_2__r.Agent_Name__c
                FROM AgentGov_Conflict_Log__c
                WITH USER_MODE
                ORDER BY Timestamp__c DESC
                LIMIT :rowLimit
            ];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * @description Counts the action log rows written since midnight in the org's time zone,
     *              leaving out Alert rows and administrators' Admin rows, so the figure follows
     *              agents' actions, refusals, and usage reports. System rows are counted: they
     *              also record an agent's request of an unrecognised action type, besides the
     *              framework's own occasional events. Filters on CreatedDate, which is indexed,
     *              so the count stays fast on a large log.
     * @return The number of rows
     */
    @AuraEnabled(cacheable=true)
    public static Integer getTodaysActionCount() {
        DateTime dayStart = orgDayStart(AgentGovBudgetManager.budgetDate());
        DateTime dayEnd = dayStart.addDays(1);
        try {
            return [
                SELECT COUNT()
                FROM AgentGov_Action_Log__c
                WHERE
                    CreatedDate >= :dayStart
                    AND CreatedDate < :dayEnd
                    AND Action_Type__c NOT IN :NON_AGENT_ACTION_TYPES
                WITH USER_MODE
            ];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * @description Returns live sessions, most recently active first: active and used within
     *              the idle window, so the list is accurate even when the health check that
     *              closes idle sessions is not scheduled.
     * @return The live sessions, up to 200
     */
    @AuraEnabled(cacheable=true)
    public static List<AgentGov_Session__c> getActiveSessions() {
        DateTime now = DateTime.now();
        DateTime idleCutoff = now.addMinutes(-sessionIdleMinutes());
        DateTime maxStartCutoff = now.addHours(-AgentGovConstants.MAX_SESSION_HOURS);
        try {
            return [
                SELECT
                    Id,
                    Agent_Registration__c,
                    Agent_Registration__r.Agent_Name__c,
                    Session_Start__c,
                    Last_Activity__c,
                    Status__c,
                    API_Calls_Used__c,
                    SOQL_Queries_Used__c,
                    DML_Statements_Used__c,
                    Actions_Count__c
                FROM AgentGov_Session__c
                WHERE
                    Status__c = :AgentGovConstants.SESSION_ACTIVE
                    AND Last_Activity__c >= :idleCutoff
                    AND Session_Start__c >= :maxStartCutoff
                WITH USER_MODE
                ORDER BY Last_Activity__c DESC
                LIMIT :MAX_SESSIONS
            ];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * @description Counts agents whose circuit breaker is OPEN.
     * @return The number of agents
     */
    @AuraEnabled(cacheable=true)
    public static Integer getTrippedCircuitBreakerCount() {
        try {
            return [
                SELECT COUNT()
                FROM AgentGov_Registration__c
                WHERE Circuit_Breaker_State__c = :AgentGovConstants.CB_OPEN
                WITH USER_MODE
            ];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * @description Returns every agent the viewer can see, up to 2,000, with today's budget
     *              usage and its live session, for the console's agent list.
     * @return One summary per agent, by agent name
     */
    @AuraEnabled(cacheable=true)
    public static List<AgentSummary> getAgentSummaries() {
        try {
            return summarize(null);
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * @description Returns one agent with today's budget usage and its live session.
     * @param registrationId The agent
     * @return The summary, or null when the viewer cannot see the agent
     */
    @AuraEnabled(cacheable=true)
    public static AgentSummary getAgentSummary(Id registrationId) {
        try {
            List<AgentSummary> summaries = summarize(registrationId);
            return summaries.isEmpty() ? null : summaries[0];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * @description Returns one page of the action log, newest first. Every filter is optional.
     *              Pages are keyed on CreatedDate and Id, both indexed, so paging stays fast on
     *              a large log.
     * @param registrationId Only this agent's rows
     * @param status Only rows with this status
     * @param actionType Only rows of this action type
     * @param windowHours Only rows from the last this many hours
     * @param correlationId Only rows from this request
     * @param beforeCreatedDate With beforeId, the position after which the page starts
     * @param beforeId The Id of the last row of the previous page
     * @param pageSize Rows per page, at most 200
     * @return The page
     */
    @AuraEnabled(cacheable=true)
    @SuppressWarnings('PMD.ExcessiveParameterList')
    public static ActionLogPage getActionLogs(
        Id registrationId,
        String status,
        String actionType,
        Integer windowHours,
        String correlationId,
        DateTime beforeCreatedDate,
        Id beforeId,
        Integer pageSize
    ) {
        Integer size = pageSize == null || pageSize < 1 ? DEFAULT_LOG_PAGE : Math.min(pageSize, MAX_LOG_PAGE);
        Map<String, Object> binds = new Map<String, Object>{ 'rowLimit' => size + 1 };
        List<String> filters = new List<String>();
        addFilter(filters, binds, 'Agent_Registration__c = :agentId', 'agentId', registrationId);
        addFilter(filters, binds, 'Status__c = :status', 'status', String.isBlank(status) ? null : status);
        addFilter(
            filters,
            binds,
            'Action_Type__c = :actionType',
            'actionType',
            String.isBlank(actionType) ? null : actionType
        );
        addFilter(
            filters,
            binds,
            'Correlation_Id__c = :correlationId',
            'correlationId',
            String.isBlank(correlationId) ? null : correlationId
        );
        if (windowHours != null && windowHours > 0) {
            addFilter(filters, binds, 'CreatedDate >= :since', 'since', DateTime.now().addHours(-windowHours));
        }
        if (beforeCreatedDate != null && beforeId != null) {
            binds.put('beforeDate', beforeCreatedDate);
            binds.put('beforeId', beforeId);
            filters.add('(CreatedDate < :beforeDate OR (CreatedDate = :beforeDate AND Id < :beforeId))');
        }
        // The field list and filter clauses are fixed text; every caller value is a bind.
        String soql =
            'SELECT Id, CreatedDate, Timestamp__c, Agent_Registration__c, Agent_Registration__r.Agent_Name__c, ' +
            'Action_Type__c, Status__c, Object_Name__c, Record_Id__c, Details__c, Error_Message__c, ' +
            'Execution_Time_Ms__c, Correlation_Id__c, Agent_Session__c FROM AgentGov_Action_Log__c' +
            (filters.isEmpty() ? '' : ' WHERE ' + String.join(filters, ' AND ')) +
            ' ORDER BY CreatedDate DESC, Id DESC LIMIT :rowLimit';
        try {
            List<AgentGov_Action_Log__c> rows = Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
            ActionLogPage page = new ActionLogPage();
            page.hasMore = rows.size() > size;
            if (page.hasMore) {
                rows.remove(rows.size() - 1);
            }
            page.rows = rows;
            return page;
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * @description Returns daily budget usage, oldest day first, from the budget rows the
     *              framework keeps for every agent and day. For one agent the rows are its own;
     *              without an agent, usage is summed across every agent the viewer can see.
     * @param registrationId The agent, or null for the whole org
     * @param days Days to return, at most 90
     * @return One entry per day that has budget rows
     */
    @AuraEnabled(cacheable=true)
    public static List<UsageDay> getUsageHistory(Id registrationId, Integer days) {
        Integer span = days == null || days < 1 ? 7 : Math.min(days, MAX_HISTORY_DAYS);
        Date since = AgentGovBudgetManager.budgetDate().addDays(1 - span);
        try {
            return registrationId == null ? orgHistory(since) : agentHistory(registrationId, since);
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * @description Returns the most recent alerts, newest first: the Alert rows the framework
     *              writes for budget escalations and circuit breaker trips. None are written
     *              while Enable Real Time Events is unchecked in AgentGov Settings.
     * @param limitCount Rows to return, at most 100
     * @return The Alert rows, newest first
     */
    @AuraEnabled(cacheable=true)
    public static List<AgentGov_Action_Log__c> getRecentAlerts(Integer limitCount) {
        Integer rowLimit = limitCount == null || limitCount < 1 ? 10 : Math.min(limitCount, MAX_ALERTS);
        try {
            return [
                SELECT
                    Id,
                    CreatedDate,
                    Timestamp__c,
                    Agent_Registration__c,
                    Agent_Registration__r.Agent_Name__c,
                    Details__c
                FROM AgentGov_Action_Log__c
                WHERE Action_Type__c = :AgentGovConstants.ACTION_ALERT
                WITH USER_MODE
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT :rowLimit
            ];
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    private static List<AgentSummary> summarize(Id onlyAgent) {
        String agentFilter = onlyAgent == null ? '' : ' WHERE Id = :onlyAgent';
        List<AgentGov_Registration__c> agents = Database.queryWithBinds(
            'SELECT Id, Agent_Name__c, Agent_Type__c, Status__c, Circuit_Breaker_State__c, Cooldown_Until__c, ' +
                'Failure_Count__c, Priority__c, Last_Active__c, API_Key_Prefix__c, API_Key_Last_Rotated__c, Agent_User__c ' +
                'FROM AgentGov_Registration__c' +
                agentFilter +
                ' ORDER BY Agent_Name__c LIMIT :maxAgents',
            new Map<String, Object>{ 'onlyAgent' => onlyAgent, 'maxAgents' => MAX_AGENTS },
            AccessLevel.USER_MODE
        );
        Set<Id> agentIds = new Map<Id, AgentGov_Registration__c>(agents).keySet();
        Date today = AgentGovBudgetManager.budgetDate();
        Map<Id, AgentGov_Budget__c> budgets = new Map<Id, AgentGov_Budget__c>();
        for (AgentGov_Budget__c budget : [
            SELECT
                Agent_Registration__c,
                Budget_Status__c,
                Peak_Usage_Percent__c,
                API_Calls_Allocated__c,
                API_Calls_Consumed__c,
                SOQL_Queries_Allocated__c,
                SOQL_Queries_Consumed__c,
                DML_Operations_Allocated__c,
                DML_Operations_Consumed__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c IN :agentIds AND Budget_Date__c = :today
            WITH USER_MODE
        ]) {
            budgets.put(budget.Agent_Registration__c, budget);
        }
        Map<Id, AgentGov_Session__c> sessions = liveSessionsByAgent(agentIds);
        Set<Id> keyHolders = agentsWithKeysInKeyFields(agentIds);
        List<AgentSummary> summaries = new List<AgentSummary>();
        for (AgentGov_Registration__c agent : agents) {
            AgentSummary summary = toSummary(agent, budgets.get(agent.Id), sessions.get(agent.Id));
            summary.hasApiKey = summary.hasApiKey || keyHolders.contains(agent.Id);
            summaries.add(summary);
        }
        return summaries;
    }

    // Each agent's own live session, read for those agents only: the org-wide list of live
    // sessions is capped, so an agent's session could be missing from it. Most recent first, so
    // an agent with more than one live session shows its latest.
    private static Map<Id, AgentGov_Session__c> liveSessionsByAgent(Set<Id> agentIds) {
        DateTime now = DateTime.now();
        DateTime idleCutoff = now.addMinutes(-sessionIdleMinutes());
        DateTime maxStartCutoff = now.addHours(-AgentGovConstants.MAX_SESSION_HOURS);
        Map<Id, AgentGov_Session__c> sessions = new Map<Id, AgentGov_Session__c>();
        for (AgentGov_Session__c session : [
            SELECT Id, Agent_Registration__c, Actions_Count__c
            FROM AgentGov_Session__c
            WHERE
                Agent_Registration__c IN :agentIds
                AND Status__c = :AgentGovConstants.SESSION_ACTIVE
                AND Last_Activity__c >= :idleCutoff
                AND Session_Start__c >= :maxStartCutoff
            WITH USER_MODE
            ORDER BY Last_Activity__c DESC
        ]) {
            if (!sessions.containsKey(session.Agent_Registration__c)) {
                sessions.put(session.Agent_Registration__c, session);
            }
        }
        return sessions;
    }

    // A key stored as a hash also stamps API_Key_Last_Rotated__c, which every viewer can read,
    // so toSummary sees it. A plaintext key that has not been converted yet shows only in the
    // key fields, so it is found here, and only for people allowed to read those fields.
    private static Set<Id> agentsWithKeysInKeyFields(Set<Id> agentIds) {
        if (
            agentIds.isEmpty() ||
            !AgentGov_Registration__c.API_Key__c.getDescribe().isAccessible() ||
            !AgentGov_Registration__c.API_Key_Hash__c.getDescribe().isAccessible()
        ) {
            return new Set<Id>();
        }
        return new Map<Id, AgentGov_Registration__c>(
                [
                    SELECT Id
                    FROM AgentGov_Registration__c
                    WHERE Id IN :agentIds AND (API_Key_Hash__c != NULL OR API_Key__c != NULL)
                    WITH USER_MODE
                ]
            )
            .keySet();
    }

    private static AgentSummary toSummary(
        AgentGov_Registration__c agent,
        AgentGov_Budget__c budget,
        AgentGov_Session__c session
    ) {
        AgentSummary summary = new AgentSummary();
        summary.id = agent.Id;
        summary.name = agent.Agent_Name__c;
        summary.agentType = agent.Agent_Type__c;
        summary.status = agent.Status__c;
        summary.breakerState = agent.Circuit_Breaker_State__c;
        summary.cooldownUntil = agent.Cooldown_Until__c;
        summary.failureCount = agent.Failure_Count__c;
        summary.priority = agent.Priority__c;
        summary.lastActive = agent.Last_Active__c;
        summary.apiKeyPrefix = agent.API_Key_Prefix__c;
        summary.apiKeyLastRotated = agent.API_Key_Last_Rotated__c;
        summary.hasApiKey = agent.API_Key_Prefix__c != null || agent.API_Key_Last_Rotated__c != null;
        summary.boundToUser = agent.Agent_User__c != null;
        if (budget != null) {
            summary.budgetStatus = budget.Budget_Status__c;
            // Percent formula fields come back as a percentage, for example 85.0 for 85%.
            summary.peakUsagePercent = budget.Peak_Usage_Percent__c;
            summary.apiUsagePercent = percent(budget.API_Calls_Consumed__c, budget.API_Calls_Allocated__c);
            summary.soqlUsagePercent = percent(budget.SOQL_Queries_Consumed__c, budget.SOQL_Queries_Allocated__c);
            summary.dmlUsagePercent = percent(budget.DML_Operations_Consumed__c, budget.DML_Operations_Allocated__c);
        }
        if (session != null) {
            summary.liveSessionId = session.Id;
            summary.sessionActions = session.Actions_Count__c;
        }
        return summary;
    }

    private static List<UsageDay> agentHistory(Id registrationId, Date since) {
        List<UsageDay> history = new List<UsageDay>();
        for (AgentGov_Budget__c budget : [
            SELECT
                Budget_Date__c,
                Budget_Status__c,
                Peak_Usage_Percent__c,
                API_Calls_Consumed__c,
                SOQL_Queries_Consumed__c,
                DML_Operations_Consumed__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c = :registrationId AND Budget_Date__c >= :since
            WITH USER_MODE
            ORDER BY Budget_Date__c ASC
            LIMIT :MAX_HISTORY_DAYS
        ]) {
            UsageDay day = new UsageDay();
            day.day = budget.Budget_Date__c;
            day.apiCalls = budget.API_Calls_Consumed__c;
            day.soqlQueries = budget.SOQL_Queries_Consumed__c;
            day.dmlOperations = budget.DML_Operations_Consumed__c;
            day.peakUsagePercent = budget.Peak_Usage_Percent__c;
            day.budgetStatus = budget.Budget_Status__c;
            history.add(day);
        }
        return history;
    }

    private static List<UsageDay> orgHistory(Date since) {
        List<UsageDay> history = new List<UsageDay>();
        for (AggregateResult row : [
            SELECT
                Budget_Date__c day,
                SUM(API_Calls_Consumed__c) api,
                SUM(SOQL_Queries_Consumed__c) soql,
                SUM(DML_Operations_Consumed__c) dml,
                SUM(API_Calls_Allocated__c) apiAllocated,
                SUM(SOQL_Queries_Allocated__c) soqlAllocated,
                SUM(DML_Operations_Allocated__c) dmlAllocated
            FROM AgentGov_Budget__c
            WHERE Budget_Date__c >= :since
            WITH USER_MODE
            GROUP BY Budget_Date__c
            ORDER BY Budget_Date__c ASC
        ]) {
            UsageDay day = new UsageDay();
            day.day = (Date) row.get('day');
            day.apiCalls = (Decimal) row.get('api');
            day.soqlQueries = (Decimal) row.get('soql');
            day.dmlOperations = (Decimal) row.get('dml');
            // Across the org, peak usage is the busiest limit type's share of all allocations.
            day.peakUsagePercent = Math.max(
                percent(day.apiCalls, (Decimal) row.get('apiAllocated')),
                Math.max(
                    percent(day.soqlQueries, (Decimal) row.get('soqlAllocated')),
                    percent(day.dmlOperations, (Decimal) row.get('dmlAllocated'))
                )
            );
            history.add(day);
        }
        return history;
    }

    // Matches the budget ledger: a zero allocation with any usage counts as full.
    private static Decimal percent(Decimal consumed, Decimal allocated) {
        Decimal used = consumed == null ? 0 : consumed;
        if (allocated == null || allocated <= 0) {
            return used > 0 ? 100 : 0;
        }
        return (used / allocated * 100).setScale(1);
    }

    private static void addFilter(
        List<String> filters,
        Map<String, Object> binds,
        String clause,
        String bindName,
        Object value
    ) {
        if (value != null) {
            filters.add(clause);
            binds.put(bindName, value);
        }
    }

    /**
     * @description Returns the instant the given date begins in the org's time zone.
     * @param orgDate A date in the org's calendar
     * @return Midnight at the start of that date, as an absolute time
     */
    @TestVisible
    private static DateTime orgDayStart(Date orgDate) {
        TimeZone orgZone = TimeZone.getTimeZone(AgentGovSelector.getOrgTimeZone());
        DateTime midnightGmt = DateTime.newInstanceGmt(orgDate, Time.newInstance(0, 0, 0, 0));
        return midnightGmt.addSeconds(-orgZone.getOffset(midnightGmt) / 1000);
    }

    private static Integer sessionIdleMinutes() {
        Decimal configured = AgentGovSelector.getSettings().Session_Idle_Minutes__c;
        if (configured == null || configured < 1 || configured > AgentGovConstants.MAX_SESSION_IDLE_MINUTES) {
            return AgentGovConstants.DEFAULT_SESSION_IDLE_MINUTES;
        }
        return configured.intValue();
    }

    /**
     * @description Converts a user-mode access failure into a message the component can show.
     *              The platform message names the inaccessible object or field, which is
     *              exactly what an administrator needs in order to fix the permission set.
     *              User mode raises SecurityException when the object itself is out of reach
     *              and QueryException when a field is, so both are treated as access failures;
     *              anything else is re-thrown so a real defect is not disguised as a
     *              permission problem.
     * @param failure The exception raised by the query
     * @return An exception carrying a message the Lightning component can display
     */
    private static AuraHandledException toAuraException(Exception failure) {
        if (!(failure instanceof QueryException) && !(failure instanceof SecurityException)) {
            throw failure;
        }
        String message =
            'You do not have access to some AgentGov data. Ask an administrator for the AgentGov User permission set. (' +
            failure.getMessage() +
            ')';
        AuraHandledException aura = new AuraHandledException(message);
        // AuraHandledException hides its constructor message from clients unless it is set explicitly.
        aura.setMessage(message);
        return aura;
    }
}
