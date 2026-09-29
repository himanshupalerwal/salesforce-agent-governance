/**
 * @description Tests for the dashboard controller's read methods. Access behaviour for
 *              restricted viewers is covered in AgentGovSecurityTest.
 */
@IsTest
private class AgentGovDashboardControllerTest {
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

    @IsTest
    static void readsEveryDashboardDataset() {
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
            Assert.areEqual(1, AgentGovDashboardController.getTodaysActionCount());
            Assert.areEqual(1, AgentGovDashboardController.getActiveSessions().size());
            Assert.areEqual(1, AgentGovDashboardController.getTrippedCircuitBreakerCount());
        }
    }

    @IsTest
    static void conflictLimitDefaultsWhenInvalid() {
        Assert.areEqual(1, AgentGovDashboardController.getRecentConflictLogs(null).size());
        Assert.areEqual(1, AgentGovDashboardController.getRecentConflictLogs(0).size());
    }

    @IsTest
    static void everyMethodRefusesAViewerWithoutAccess() {
        User outsider = AgentGovTestDataFactory.createRestrictedUser(new List<String>());
        Integer refusals = 0;
        System.runAs(outsider) {
            try {
                AgentGovDashboardController.getAllTodaysBudgets();
            } catch (AuraHandledException e) {
                refusals++;
            }
            try {
                AgentGovDashboardController.getRecentConflictLogs(5);
            } catch (AuraHandledException e) {
                refusals++;
            }
            try {
                AgentGovDashboardController.getTodaysActionCount();
            } catch (AuraHandledException e) {
                refusals++;
            }
            try {
                AgentGovDashboardController.getActiveSessions();
            } catch (AuraHandledException e) {
                refusals++;
            }
            try {
                AgentGovDashboardController.getTrippedCircuitBreakerCount();
            } catch (AuraHandledException e) {
                refusals++;
            }
        }
        Assert.areEqual(5, refusals, 'Every read is refused for a user without the permission set');
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
        Assert.areEqual(busy.id, single.id);
    }

    @IsTest
    static void actionLogsAreFilteredAndPaged() {
        Id agent = [SELECT Id FROM AgentGov_Registration__c WHERE Agent_Name__c = 'Test Agent 0'].Id;
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
    static void usageHistoryIsReadFromTheDailyBudgets() {
        Id agent = [SELECT Id FROM AgentGov_Registration__c WHERE Agent_Name__c = 'Test Agent 0'].Id;
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
        Id agent = [SELECT Id FROM AgentGov_Registration__c WHERE Agent_Name__c = 'Test Agent 1'].Id;
        insert new AgentGov_Action_Log__c(
            Agent_Registration__c = agent,
            Action_Type__c = AgentGovConstants.ACTION_ALERT,
            Status__c = AgentGovConstants.ACTION_SUCCESS,
            Timestamp__c = DateTime.now(),
            Details__c = 'Warning alert for agent Test Agent 1'
        );
        // A session left open but idle for hours is not live.
        AgentGov_Session__c idle = AgentGovTestDataFactory.createSession(agent, false);
        idle.Session_Start__c = DateTime.now().addHours(-3);
        idle.Last_Activity__c = DateTime.now().addHours(-3);
        insert idle;

        Assert.areEqual(1, AgentGovDashboardController.getRecentAlerts(5).size());
        Assert.areEqual(1, AgentGovDashboardController.getActiveSessions().size(), 'Only the live session is listed');
    }
}
