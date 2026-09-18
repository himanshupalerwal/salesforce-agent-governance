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
}
