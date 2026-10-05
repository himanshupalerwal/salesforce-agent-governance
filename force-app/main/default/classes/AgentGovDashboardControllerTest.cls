/**
 * @description Tests for the dashboard controller's read methods: every read answered for a
 *              viewer with AgentGov_User and refused for a viewer without it; the console's agent
 *              summaries, including API keys with no stored prefix and live sessions beyond the
 *              overview's list; the filtered and paged action log; usage history; alerts; what
 *              the day's action count includes; and the caps and defaults on how much one read
 *              returns. AgentGovSecurityTest also covers getAllRegistrations for both kinds of
 *              viewer.
 */
@IsTest
private class AgentGovDashboardControllerTest {
    // Every @AuraEnabled read of AgentGovDashboardController, by name.
    private static final List<String> READS = new List<String>{
        'getAllRegistrations',
        'getAllTodaysBudgets',
        'getRecentConflictLogs',
        'getTodaysActionCount',
        'getActiveSessions',
        'getTrippedCircuitBreakerCount',
        'getAgentSummaries',
        'getAgentSummary',
        'getActionLogs',
        'getUsageHistory',
        'getRecentAlerts'
    };

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        List<AgentGov_Registration__c> agents = AgentGovTestDataFactory.createRegistrations(2, 'Agentforce');
        agents[1].Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        update agents[1];
        AgentGovTestDataFactory.createBudget(agents[0].Id, true);
        AgentGov_Session__c session = AgentGovTestDataFactory.createSession(agents[0].Id, true);
        AgentGovTestDataFactory.createActionLog(
            agents[0].Id,
            session.Id,
            AgentGovConstants.ACTION_QUERY,
            AgentGovConstants.ACTION_SUCCESS,
            true
        );
        AgentGovTestDataFactory.createConflictLog(agents[0].Id, agents[1].Id, true);
    }

    private static Id agentNamed(String name) {
        return [SELECT Id FROM AgentGov_Registration__c WHERE Agent_Name__c = :name].Id;
    }

    private static AgentGov_Action_Log__c alertRow(Id agentId) {
        return new AgentGov_Action_Log__c(
            Agent_Registration__c = agentId,
            Action_Type__c = AgentGovConstants.ACTION_ALERT,
            Status__c = AgentGovConstants.ACTION_SUCCESS,
            Timestamp__c = DateTime.now(),
            Details__c = 'Warning: API calls at 85% of today\'s budget (8500 of 10000).'
        );
    }

    private static Map<String, AgentGovDashboardController.AgentSummary> byName(
        List<AgentGovDashboardController.AgentSummary> summaries
    ) {
        Map<String, AgentGovDashboardController.AgentSummary> named = new Map<String, AgentGovDashboardController.AgentSummary>();
        for (AgentGovDashboardController.AgentSummary summary : summaries) {
            named.put(summary.name, summary);
        }
        return named;
    }

    // Calls one read as the running user and reports whether it was refused.
    private static Boolean isRefused(String read, Id agentId) {
        try {
            switch on read {
                when 'getAllRegistrations' {
                    AgentGovDashboardController.getAllRegistrations();
                }
                when 'getAllTodaysBudgets' {
                    AgentGovDashboardController.getAllTodaysBudgets();
                }
                when 'getRecentConflictLogs' {
                    AgentGovDashboardController.getRecentConflictLogs(5);
                }
                when 'getTodaysActionCount' {
                    AgentGovDashboardController.getTodaysActionCount();
                }
                when 'getActiveSessions' {
                    AgentGovDashboardController.getActiveSessions();
                }
                when 'getTrippedCircuitBreakerCount' {
                    AgentGovDashboardController.getTrippedCircuitBreakerCount();
                }
                when 'getAgentSummaries' {
                    AgentGovDashboardController.getAgentSummaries();
                }
                when 'getAgentSummary' {
                    AgentGovDashboardController.getAgentSummary(agentId);
                }
                when 'getActionLogs' {
                    AgentGovDashboardController.getActionLogs(agentId, null, null, null, null, null, null, null);
                }
                when 'getUsageHistory' {
                    AgentGovDashboardController.getUsageHistory(agentId, 7);
                }
                when 'getRecentAlerts' {
                    AgentGovDashboardController.getRecentAlerts(5);
                }
                when else {
                    Assert.fail('Unknown read: ' + read);
                }
            }
        } catch (AuraHandledException e) {
            return true;
        }
        return false;
    }

    @IsTest
    static void readsEveryDashboardDataset() {
        insert alertRow(agentNamed('Test Agent 1'));
        User viewer = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_User' });

        System.runAs(viewer) {
            Assert.areEqual(2, AgentGovDashboardController.getAllRegistrations().size());
            List<AgentGov_Budget__c> budgets = AgentGovDashboardController.getAllTodaysBudgets();
            Assert.areEqual(1, budgets.size());
            Assert.areEqual(
                'Test Agent 0',
                budgets[0].Agent_Registration__r.Agent_Name__c,
                'The agent name is included for display'
            );
            List<AgentGov_Conflict_Log__c> conflicts = AgentGovDashboardController.getRecentConflictLogs(10);
            Assert.areEqual(1, conflicts.size());
            Assert.areEqual('Test Agent 0', conflicts[0].Agent_1__r.Agent_Name__c);
            Assert.areEqual(1, AgentGovDashboardController.getTodaysActionCount(), 'The Alert row is not counted');
            Assert.areEqual(1, AgentGovDashboardController.getActiveSessions().size());
            Assert.areEqual(1, AgentGovDashboardController.getTrippedCircuitBreakerCount());
            List<AgentGovDashboardController.AgentSummary> summaries = AgentGovDashboardController.getAgentSummaries();
            Assert.areEqual(2, summaries.size());
            Assert.areEqual(summaries[1].id, AgentGovDashboardController.getAgentSummary(summaries[1].id).id);
            AgentGovDashboardController.ActionLogPage log = AgentGovDashboardController.getActionLogs(
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null
            );
            Assert.areEqual(2, log.rows.size(), 'The Query row and the Alert row');
            Assert.areEqual(1, AgentGovDashboardController.getUsageHistory(null, 7).size(), 'Today, summed');
            Assert.areEqual(1, AgentGovDashboardController.getRecentAlerts(5).size());
        }
    }

    @IsTest
    static void conflictLimitDefaultsWhenInvalid() {
        Assert.areEqual(1, AgentGovDashboardController.getRecentConflictLogs(null).size());
        Assert.areEqual(1, AgentGovDashboardController.getRecentConflictLogs(0).size());
    }

    @IsTest
    static void conflictReadsAreCapped() {
        List<AgentGov_Registration__c> agents = [SELECT Id FROM AgentGov_Registration__c ORDER BY Agent_Name__c];
        List<AgentGov_Conflict_Log__c> conflicts = new List<AgentGov_Conflict_Log__c>();
        for (Integer i = 0; i < 200; i++) {
            conflicts.add(AgentGovTestDataFactory.createConflictLog(agents[0].Id, agents[1].Id, false));
        }
        insert conflicts;

        Assert.areEqual(
            200,
            AgentGovDashboardController.getRecentConflictLogs(1000).size(),
            'At most 200 of the 201 conflicts are returned, however many are asked for'
        );
    }

    @IsTest
    static void everyMethodRefusesAViewerWithoutAccess() {
        User outsider = AgentGovTestDataFactory.createRestrictedUser(new List<String>());
        Id agent = agentNamed('Test Agent 0');

        List<String> answered = new List<String>();
        System.runAs(outsider) {
            for (String read : READS) {
                if (!isRefused(read, agent)) {
                    answered.add(read);
                }
            }
        }

        Assert.isTrue(answered.isEmpty(), 'Answered a user without the permission set: ' + String.join(answered, ', '));
    }

    @IsTest
    static void agentSummariesCombineTheAgentItsBudgetAndItsLiveSession() {
        User viewer = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_User' });

        List<AgentGovDashboardController.AgentSummary> summaries;
        AgentGovDashboardController.AgentSummary single;
        System.runAs(viewer) {
            summaries = AgentGovDashboardController.getAgentSummaries();
            single = AgentGovDashboardController.getAgentSummary(summaries[0].id);
        }

        Assert.areEqual(2, summaries.size());
        AgentGovDashboardController.AgentSummary busy = summaries[0];
        Assert.areEqual('Test Agent 0', busy.name);
        Assert.areEqual(AgentGovConstants.BUDGET_NORMAL, busy.budgetStatus);
        Assert.areEqual(0, busy.peakUsagePercent.intValue());
        Assert.isNotNull(busy.liveSessionId, 'The live session is attached');
        Assert.areEqual(AgentGovConstants.CB_OPEN, summaries[1].breakerState);
        Assert.isNull(summaries[1].budgetStatus, 'An agent without a budget today has no status');
        Assert.isNull(summaries[1].liveSessionId, 'An agent without a live session has none attached');
        Assert.areEqual(busy.id, single.id);
        Assert.areEqual(busy.liveSessionId, single.liveSessionId);
    }

    @IsTest
    static void aKeyWithoutAStoredPrefixIsStillReportedAsIssued() {
        AgentGovTestDataFactory.createRegistrationWithApiKey(
            'Current Key',
            'Custom_Apex',
            AgentGovRestAuth.generateKey()
        );
        AgentGovTestDataFactory.createRegistrationWithApiKey('Short Key', 'Custom_Apex', 'short-old-key');
        AgentGovTestDataFactory.createRegistrationWithLegacyKey('Legacy Key', 'Custom_Apex', 'legacy-plaintext-key');
        AgentGovTestDataFactory.createRegistration('No Key', 'Custom_Apex', true);
        User admin = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Admin' });
        User viewer = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_User' });

        Map<String, AgentGovDashboardController.AgentSummary> asAdmin;
        Map<String, AgentGovDashboardController.AgentSummary> asViewer;
        System.runAs(admin) {
            asAdmin = byName(AgentGovDashboardController.getAgentSummaries());
        }
        System.runAs(viewer) {
            asViewer = byName(AgentGovDashboardController.getAgentSummaries());
        }

        Assert.isNotNull(asViewer.get('Current Key').apiKeyPrefix);
        Assert.isTrue(asViewer.get('Current Key').hasApiKey);
        Assert.isNull(asViewer.get('Short Key').apiKeyPrefix, 'A key too short to truncate safely has no prefix');
        Assert.isTrue(asViewer.get('Short Key').hasApiKey, 'Its rotation stamp shows every viewer that it exists');
        Assert.isTrue(asAdmin.get('Short Key').hasApiKey);
        Assert.isTrue(
            asAdmin.get('Legacy Key').hasApiKey,
            'A plaintext key not yet converted is found for people who may read the key fields'
        );
        Assert.isFalse(
            asViewer.get('Legacy Key').hasApiKey,
            'Fields a viewer may not read are not used to answer for them'
        );
        Assert.isFalse(asAdmin.get('No Key').hasApiKey);
        Assert.isFalse(asViewer.get('No Key').hasApiKey);
    }

    @IsTest
    static void anAgentsLiveSessionIsFoundBeyondTheSessionsTheOverviewLists() {
        List<AgentGov_Registration__c> busy = new List<AgentGov_Registration__c>();
        for (Integer i = 0; i < 200; i++) {
            busy.add(AgentGovTestDataFactory.createRegistration('Busy Agent ' + i, 'Custom_Apex', false));
        }
        insert busy;
        List<AgentGov_Session__c> sessions = new List<AgentGov_Session__c>();
        for (AgentGov_Registration__c agent : busy) {
            sessions.add(AgentGovTestDataFactory.createSession(agent.Id, false));
        }
        insert sessions;
        // Test Agent 0's session, live but the least recently active of 201, falls outside the
        // 200 most recent that getActiveSessions returns.
        Id agent = agentNamed('Test Agent 0');
        AgentGov_Session__c quiet = [SELECT Id FROM AgentGov_Session__c WHERE Agent_Registration__c = :agent];
        quiet.Last_Activity__c = DateTime.now().addMinutes(-10);
        update quiet;

        List<AgentGov_Session__c> listed = AgentGovDashboardController.getActiveSessions();
        AgentGovDashboardController.AgentSummary summary = AgentGovDashboardController.getAgentSummary(agent);

        Assert.areEqual(200, listed.size(), 'The overview lists at most 200 live sessions');
        Assert.isFalse(
            new Map<Id, AgentGov_Session__c>(listed).containsKey(quiet.Id),
            'The quiet session is not listed'
        );
        Assert.areEqual(quiet.Id, summary.liveSessionId, 'The agent\'s own summary still finds its live session');
    }

    @IsTest
    static void actionLogsAreFilteredAndPaged() {
        Id agent = agentNamed('Test Agent 0');
        List<AgentGov_Action_Log__c> more = new List<AgentGov_Action_Log__c>();
        for (Integer i = 0; i < 4; i++) {
            more.add(
                AgentGovTestDataFactory.createActionLog(
                    agent,
                    null,
                    AgentGovConstants.ACTION_CREATE,
                    AgentGovConstants.ACTION_DENIED,
                    false
                )
            );
        }
        insert more;

        AgentGovDashboardController.ActionLogPage first = AgentGovDashboardController.getActionLogs(
            agent,
            AgentGovConstants.ACTION_DENIED,
            null,
            24,
            null,
            null,
            null,
            3
        );
        AgentGov_Action_Log__c last = first.rows[first.rows.size() - 1];
        AgentGovDashboardController.ActionLogPage second = AgentGovDashboardController.getActionLogs(
            agent,
            AgentGovConstants.ACTION_DENIED,
            null,
            24,
            null,
            last.CreatedDate,
            last.Id,
            3
        );

        Assert.areEqual(3, first.rows.size());
        Assert.isTrue(first.hasMore);
        Assert.areEqual(1, second.rows.size(), 'The second page holds the remaining denied row');
        Assert.isFalse(second.hasMore);
        for (AgentGov_Action_Log__c row : first.rows) {
            Assert.areEqual(AgentGovConstants.ACTION_DENIED, row.Status__c, 'Only the requested status');
        }
    }

    @IsTest
    static void todaysActionCountLeavesOutAlertsAndAdministratorsChanges() {
        Id agent = agentNamed('Test Agent 0');
        List<AgentGov_Action_Log__c> rows = new List<AgentGov_Action_Log__c>();
        for (String actionType : new List<String>{ AgentGovConstants.ACTION_ALERT, AgentGovConstants.ACTION_ADMIN }) {
            rows.add(
                AgentGovTestDataFactory.createActionLog(
                    agent,
                    null,
                    actionType,
                    AgentGovConstants.ACTION_SUCCESS,
                    false
                )
            );
        }
        // An agent's request of an unrecognised action type is recorded as a System row.
        for (String actionType : new List<String>{ AgentGovConstants.ACTION_CREATE, AgentGovConstants.ACTION_SYSTEM }) {
            rows.add(
                AgentGovTestDataFactory.createActionLog(agent, null, actionType, AgentGovConstants.ACTION_DENIED, false)
            );
        }
        insert rows;

        Assert.areEqual(
            3,
            AgentGovDashboardController.getTodaysActionCount(),
            'The Query row from setup and the two refused requests are counted; the Alert and Admin rows are not'
        );
    }

    @IsTest
    static void usageHistoryIsReadFromTheDailyBudgets() {
        Id agent = agentNamed('Test Agent 0');
        AgentGov_Budget__c yesterday = AgentGovTestDataFactory.createBudget(agent, false);
        yesterday.Budget_Date__c = AgentGovBudgetManager.budgetDate().addDays(-1);
        yesterday.API_Calls_Consumed__c = 5000;
        insert yesterday;

        List<AgentGovDashboardController.UsageDay> mine = AgentGovDashboardController.getUsageHistory(agent, 7);
        List<AgentGovDashboardController.UsageDay> org = AgentGovDashboardController.getUsageHistory(null, 7);

        Assert.areEqual(2, mine.size(), 'Yesterday and today');
        Assert.areEqual(5000, mine[0].apiCalls.intValue());
        Assert.areEqual(50, mine[0].peakUsagePercent.intValue(), 'Peak usage is the busiest limit type');
        Assert.areEqual(2, org.size());
        Assert.areEqual(50, org[0].peakUsagePercent.intValue());
    }

    @IsTest
    static void recentAlertsAndLiveSessionsOnly() {
        Id agent = agentNamed('Test Agent 1');
        insert alertRow(agent);
        // A session left open but idle for hours is not live.
        AgentGov_Session__c idle = AgentGovTestDataFactory.createSession(agent, false);
        idle.Session_Start__c = DateTime.now().addHours(-3);
        idle.Last_Activity__c = DateTime.now().addHours(-3);
        insert idle;

        Assert.areEqual(1, AgentGovDashboardController.getRecentAlerts(5).size());
        Assert.areEqual(1, AgentGovDashboardController.getActiveSessions().size(), 'Only the live session is listed');
    }
}
