/**
 * @description Tests for automatic session tracking: opening, extending and closing runs, the
 *              one-active-session guard, recovery from a lost race, action counting, and the
 *              agent's last-active time.
 */
@IsTest
private class AgentGovSessionTrackerTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGovTestDataFactory.createRegistration('Tracked', AgentGovConstants.AGENT_TYPE_CUSTOM_APEX, true);
    }

    private static Id agentId() {
        return [SELECT Id FROM AgentGov_Registration__c WHERE Agent_Name__c = 'Tracked' LIMIT 1].Id;
    }

    private static List<AgentGov_Session__c> sessionsOf(Id registrationId) {
        return [
            SELECT
                Id,
                Status__c,
                End_Reason__c,
                Session_End__c,
                Last_Activity__c,
                Active_Session_Key__c,
                Actions_Count__c,
                API_Calls_Used__c,
                SOQL_Queries_Used__c
            FROM AgentGov_Session__c
            WHERE Agent_Registration__c = :registrationId
            ORDER BY Session_Start__c ASC
        ];
    }

    @IsTest
    static void firstGovernedActionOpensASession() {
        Id agent = agentId();

        Test.startTest();
        AgentGovBudgetManager.consumeBudget(agent, AgentGovConstants.LIMIT_API_CALLS, 2);
        Test.stopTest();

        List<AgentGov_Session__c> sessions = sessionsOf(agent);
        Assert.areEqual(1, sessions.size());
        Assert.areEqual(AgentGovConstants.SESSION_ACTIVE, sessions[0].Status__c);
        Assert.areEqual(2, sessions[0].API_Calls_Used__c);
        Assert.areEqual(1, sessions[0].Actions_Count__c);
        Assert.isNotNull(sessions[0].Last_Activity__c);
        Assert.areEqual(String.valueOf(agent), sessions[0].Active_Session_Key__c);
        Assert.areEqual(sessions[0].Id, AgentGovSessionTracker.currentSessionFor(agent));
    }

    @IsTest
    static void activityWithinTheIdleWindowExtendsTheSameSession() {
        Id agent = agentId();

        Test.startTest();
        AgentGovBudgetManager.consumeBudget(agent, AgentGovConstants.LIMIT_API_CALLS, 1);
        AgentGovBudgetManager.consumeBudget(agent, AgentGovConstants.LIMIT_SOQL_QUERIES, 3);
        Test.stopTest();

        List<AgentGov_Session__c> sessions = sessionsOf(agent);
        Assert.areEqual(1, sessions.size(), 'Steady activity stays in one run');
        Assert.areEqual(2, sessions[0].Actions_Count__c);
        Assert.areEqual(1, sessions[0].API_Calls_Used__c);
        Assert.areEqual(3, sessions[0].SOQL_Queries_Used__c);
    }

    @IsTest
    static void activityAfterTheIdleWindowClosesTheRunAndOpensANewOne() {
        Id agent = agentId();
        DateTime lastWork = DateTime.now().addHours(-2);
        AgentGov_Session__c old = AgentGovTestDataFactory.createSession(agent, false);
        old.Session_Start__c = lastWork.addMinutes(-5);
        old.Last_Activity__c = lastWork;
        insert old;

        Test.startTest();
        AgentGovBudgetManager.consumeBudget(agent, AgentGovConstants.LIMIT_API_CALLS, 1);
        Test.stopTest();

        List<AgentGov_Session__c> sessions = sessionsOf(agent);
        Assert.areEqual(2, sessions.size(), 'The idle run is closed and a new one opened in the same call');
        Assert.areEqual(AgentGovConstants.SESSION_COMPLETED, sessions[0].Status__c);
        Assert.areEqual(AgentGovConstants.SESSION_END_IDLE, sessions[0].End_Reason__c);
        Assert.areEqual(lastWork, sessions[0].Session_End__c, 'The old run ended at its last activity');
        Assert.areEqual(AgentGovConstants.SESSION_ACTIVE, sessions[1].Status__c);
        Assert.areEqual(1, sessions[1].Actions_Count__c);
    }

    @IsTest
    static void anAgentCannotHaveTwoActiveSessions() {
        Id agent = agentId();
        AgentGovTestDataFactory.createSession(agent, true);

        Boolean rejected = false;
        try {
            AgentGovTestDataFactory.createSession(agent, true);
        } catch (DmlException e) {
            rejected = e.getDmlType(0) == StatusCode.DUPLICATE_VALUE;
        }
        Assert.isTrue(rejected, 'The unique key refuses a second active session for one agent');
    }

    @IsTest
    static void aLostRaceAddsItsUsageToTheWinningSession() {
        Id agent = agentId();
        AgentGov_Session__c winner = AgentGovTestDataFactory.createSession(agent, true);
        // The tracker behaves as if another transaction had opened the session after its read.
        AgentGovSessionTracker.simulateMissedSession = true;

        Test.startTest();
        AgentGovBudgetManager.consumeBudget(agent, AgentGovConstants.LIMIT_API_CALLS, 4);
        Test.stopTest();

        List<AgentGov_Session__c> sessions = sessionsOf(agent);
        Assert.areEqual(1, sessions.size(), 'No second session was opened');
        Assert.areEqual(winner.Id, sessions[0].Id);
        Assert.areEqual(4, sessions[0].API_Calls_Used__c, 'The usage joined the winning session');
        Assert.areEqual(1, sessions[0].Actions_Count__c);
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM AgentGov_Action_Log__c WHERE Status__c = :AgentGovConstants.ACTION_FAILURE],
            'Recovering from the race is not a failure'
        );
    }

    @IsTest
    static void usageReportsAddUsageButNoAction() {
        Id agent = agentId();

        Test.startTest();
        AgentGovBudgetManager.consumeBudget(
            agent,
            new Map<String, Integer>{ AgentGovConstants.LIMIT_API_CALLS => 5 },
            0
        );
        Test.stopTest();

        AgentGov_Session__c session = sessionsOf(agent)[0];
        Assert.areEqual(5, session.API_Calls_Used__c);
        Assert.areEqual(0, session.Actions_Count__c, 'A report describes work already counted');
    }

    @IsTest
    static void aBatchCountsEveryRequestAsAnAction() {
        Id agent = agentId();

        Test.startTest();
        AgentGovBudgetManager.consumeBudgets(
            new Map<Id, Map<String, Integer>>{
                agent => new Map<String, Integer>{ AgentGovConstants.LIMIT_SOQL_QUERIES => 200 }
            },
            new Map<Id, Integer>{ agent => 200 }
        );
        Test.stopTest();

        Assert.areEqual(200, sessionsOf(agent)[0].Actions_Count__c);
    }

    @IsTest
    static void lastActiveIsRefreshedButNotOnEveryRequest() {
        Id agent = agentId();
        DateTime stale = DateTime.now().addMinutes(-5);
        update new AgentGov_Registration__c(Id = agent, Last_Active__c = stale);

        Test.startTest();
        AgentGovBudgetManager.consumeBudget(agent, AgentGovConstants.LIMIT_API_CALLS, 1);
        DateTime refreshed = [SELECT Last_Active__c FROM AgentGov_Registration__c WHERE Id = :agent].Last_Active__c;
        AgentGovBudgetManager.consumeBudget(agent, AgentGovConstants.LIMIT_API_CALLS, 1);
        Test.stopTest();

        Assert.isTrue(refreshed > stale, 'A last-active time older than a minute is refreshed');
        Assert.areEqual(
            refreshed,
            [SELECT Last_Active__c FROM AgentGov_Registration__c WHERE Id = :agent].Last_Active__c,
            'A recent last-active time is not rewritten on every request'
        );
    }

    @IsTest
    static void startSessionEndsTheCurrentRunFirst() {
        Id agent = agentId();
        AgentGov_Session__c current = AgentGovTestDataFactory.createSession(agent, true);

        Test.startTest();
        AgentGov_Session__c started = AgentGovRegistryService.startSession(agent);
        Test.stopTest();

        AgentGov_Session__c ended = [SELECT Status__c, End_Reason__c FROM AgentGov_Session__c WHERE Id = :current.Id];
        Assert.areEqual(AgentGovConstants.SESSION_COMPLETED, ended.Status__c);
        Assert.areEqual(AgentGovConstants.SESSION_END_CALLER, ended.End_Reason__c);
        Assert.areEqual(
            AgentGovConstants.SESSION_ACTIVE,
            [SELECT Status__c FROM AgentGov_Session__c WHERE Id = :started.Id].Status__c
        );
    }

    @IsTest
    static void deactivatingAnAgentEndsItsSession() {
        Id agent = agentId();
        AgentGov_Session__c current = AgentGovTestDataFactory.createSession(agent, true);

        Test.startTest();
        AgentGovRegistryService.deactivateAgent(agent);
        Test.stopTest();

        AgentGov_Session__c ended = [SELECT Status__c, End_Reason__c FROM AgentGov_Session__c WHERE Id = :current.Id];
        Assert.areEqual(AgentGovConstants.SESSION_TERMINATED, ended.Status__c);
        Assert.areEqual(AgentGovConstants.SESSION_END_DEACTIVATED, ended.End_Reason__c);
    }

    @IsTest
    static void auditRowsLinkToTheSessionTheirWorkWasRecordedIn() {
        Id agent = agentId();

        Test.startTest();
        AgentGovBudgetManager.consumeBudget(agent, AgentGovConstants.LIMIT_API_CALLS, 1);
        AgentGovTriggerHandler.logAction(
            agent,
            AgentGovConstants.ACTION_API_CALL,
            'Account',
            null,
            AgentGovConstants.ACTION_SUCCESS,
            null
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        Id sessionId = sessionsOf(agent)[0].Id;
        Assert.areEqual(
            sessionId,
            [SELECT Agent_Session__c FROM AgentGov_Action_Log__c WHERE Agent_Registration__c = :agent LIMIT 1]
            .Agent_Session__c
        );
    }
}
