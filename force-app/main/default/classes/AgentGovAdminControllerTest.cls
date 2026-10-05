/**
 * @description Tests for the console's administrative actions: the permission matrix; the Admin
 *              audit row written by every action that changes something (breaker reset,
 *              activation, deactivation, key rotation, budget credit, ended session, and job
 *              scheduling) and none for a record already in the requested state; key rotation
 *              that never records the key; credits that report how much was actually credited;
 *              a failure after the change and its audit row were written, which rolls both
 *              back; the setup status; and refusals that change nothing.
 */
@IsTest
private class AgentGovAdminControllerTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c tripped = AgentGovTestDataFactory.createRegistration('Tripped', 'MCP_External', false);
        tripped.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        tripped.Status__c = AgentGovConstants.STATUS_BLOCKED;
        tripped.Failure_Count__c = 5;
        tripped.Cooldown_Until__c = DateTime.now().addMinutes(30);
        insert tripped;
    }

    private static AgentGov_Registration__c tripped() {
        return [
            SELECT Id, Status__c, Circuit_Breaker_State__c, API_Key_Hash__c
            FROM AgentGov_Registration__c
            WHERE Agent_Name__c = 'Tripped'
        ];
    }

    private static List<AgentGov_Action_Log__c> adminRows() {
        return [
            SELECT Agent_Registration__c, Details__c, CreatedById, Correlation_Id__c
            FROM AgentGov_Action_Log__c
            WHERE Action_Type__c = :AgentGovConstants.ACTION_ADMIN
        ];
    }

    private static User administrator() {
        return AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Admin' });
    }

    private static String statusOf(Id agentId) {
        return [SELECT Status__c FROM AgentGov_Registration__c WHERE Id = :agentId].Status__c;
    }

    private static AgentGov_Budget__c budgetUsing(Id agentId, Integer apiCalls, Integer soqlQueries) {
        AgentGov_Budget__c budget = AgentGovTestDataFactory.createBudget(agentId, false);
        budget.API_Calls_Consumed__c = apiCalls;
        budget.SOQL_Queries_Consumed__c = soqlQueries;
        insert budget;
        return budget;
    }

    private static AgentGov_Budget__c reload(AgentGov_Budget__c budget) {
        return [
            SELECT API_Calls_Consumed__c, SOQL_Queries_Consumed__c, DML_Operations_Consumed__c, Budget_Status__c
            FROM AgentGov_Budget__c
            WHERE Id = :budget.Id
        ];
    }

    @IsTest
    static void aViewerWithoutTheOperatePermissionIsRefused() {
        User viewer = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_User' });
        Id agent = tripped().Id;

        String message;
        System.runAs(viewer) {
            try {
                AgentGovAdminController.resetBreakers(new List<Id>{ agent });
            } catch (AuraHandledException e) {
                message = e.getMessage();
            }
        }

        Assert.areEqual(AgentGovConstants.ERR_OPERATE_PERMISSION, message);
        Assert.areEqual(AgentGovConstants.CB_OPEN, tripped().Circuit_Breaker_State__c, 'Nothing changed');
    }

    @IsTest
    static void resettingABreakerClosesItAndRecordsWhoDidIt() {
        User admin = administrator();
        Id agent = tripped().Id;

        List<AgentGovAdminController.ActionOutcome> outcomes;
        System.runAs(admin) {
            outcomes = AgentGovAdminController.resetBreakers(new List<Id>{ agent });
        }

        Assert.isTrue(outcomes[0].success, outcomes[0].message);
        AgentGov_Registration__c after = tripped();
        Assert.areEqual(AgentGovConstants.CB_CLOSED, after.Circuit_Breaker_State__c);
        Assert.areEqual(AgentGovConstants.STATUS_ACTIVE, after.Status__c);
        List<AgentGov_Action_Log__c> audit = adminRows();
        Assert.areEqual(1, audit.size());
        Assert.areEqual(agent, audit[0].Agent_Registration__c);
        Assert.areEqual(admin.Id, audit[0].CreatedById, 'The person who acted is the row creator');
        Assert.isTrue(audit[0].Details__c.contains(AgentGovConstants.CB_OPEN), 'The previous state is recorded');
        Assert.isNotNull(audit[0].Correlation_Id__c);
    }

    @IsTest
    static void aResponderCanOperateAgentsButNotRotateKeys() {
        User responder = AgentGovTestDataFactory.createRestrictedUser(
            new List<String>{ 'AgentGov_User', 'AgentGov_Responder' }
        );
        Id agent = tripped().Id;

        List<AgentGovAdminController.ActionOutcome> outcomes;
        String keyMessage;
        System.runAs(responder) {
            outcomes = AgentGovAdminController.deactivateAgents(new List<Id>{ agent });
            try {
                AgentGovAdminController.rotateApiKey(agent);
            } catch (AuraHandledException e) {
                keyMessage = e.getMessage();
            }
        }

        Assert.isTrue(outcomes[0].success, outcomes[0].message);
        Assert.areEqual('Agent deactivated.', outcomes[0].message);
        Assert.areEqual(AgentGovConstants.STATUS_INACTIVE, tripped().Status__c);
        Assert.areEqual(AgentGovConstants.ERR_MANAGE_KEYS_PERMISSION, keyMessage);
        List<AgentGov_Action_Log__c> audit = adminRows();
        Assert.areEqual(1, audit.size(), 'The deactivation is audited, and the refused rotation is not');
        Assert.areEqual(agent, audit[0].Agent_Registration__c);
        Assert.areEqual(responder.Id, audit[0].CreatedById, 'The responder is the row creator');
        Assert.isTrue(audit[0].Details__c.contains(AgentGovConstants.STATUS_BLOCKED), audit[0].Details__c);
    }

    @IsTest
    static void activatingAnInactiveAgentIsAudited() {
        User admin = administrator();
        AgentGov_Registration__c idle = AgentGovTestDataFactory.createRegistration('Idle', 'Flow_Based', false);
        idle.Status__c = AgentGovConstants.STATUS_INACTIVE;
        insert idle;

        List<AgentGovAdminController.ActionOutcome> outcomes;
        System.runAs(admin) {
            outcomes = AgentGovAdminController.activateAgents(new List<Id>{ idle.Id });
        }

        Assert.isTrue(outcomes[0].success, outcomes[0].message);
        Assert.areEqual('Agent activated.', outcomes[0].message);
        Assert.areEqual(AgentGovConstants.STATUS_ACTIVE, statusOf(idle.Id));
        List<AgentGov_Action_Log__c> audit = adminRows();
        Assert.areEqual(1, audit.size(), 'The activation is audited');
        Assert.areEqual(idle.Id, audit[0].Agent_Registration__c);
        Assert.areEqual(admin.Id, audit[0].CreatedById, 'The person who acted is the row creator');
        Assert.isTrue(audit[0].Details__c.contains(AgentGovConstants.STATUS_INACTIVE), audit[0].Details__c);
    }

    @IsTest
    static void anAgentAlreadyInTheRequestedStateIsLeftAloneWithoutAnAuditRow() {
        User admin = administrator();
        AgentGov_Registration__c running = AgentGovTestDataFactory.createRegistration('Running', 'Flow_Based', true);
        AgentGov_Registration__c idle = AgentGovTestDataFactory.createRegistration('Idle', 'Flow_Based', false);
        idle.Status__c = AgentGovConstants.STATUS_INACTIVE;
        insert idle;

        List<AgentGovAdminController.ActionOutcome> activated;
        List<AgentGovAdminController.ActionOutcome> deactivated;
        System.runAs(admin) {
            activated = AgentGovAdminController.activateAgents(new List<Id>{ running.Id });
            deactivated = AgentGovAdminController.deactivateAgents(new List<Id>{ idle.Id });
        }

        Assert.isTrue(activated[0].success, 'An active agent is already in the state activation asks for');
        Assert.areEqual('The agent was already active.', activated[0].message);
        Assert.isTrue(deactivated[0].success, 'An inactive agent is already in the state deactivation asks for');
        Assert.areEqual('The agent was already inactive.', deactivated[0].message);
        Assert.areEqual(AgentGovConstants.STATUS_ACTIVE, statusOf(running.Id));
        Assert.areEqual(AgentGovConstants.STATUS_INACTIVE, statusOf(idle.Id));
        Assert.areEqual(0, adminRows().size(), 'No audit row for a change that did not happen');
    }

    @IsTest
    static void aRotatedKeyIsReturnedOnceAndOnlyItsPrefixIsAudited() {
        User admin = administrator();
        Id agent = tripped().Id;

        AgentGovAdminController.IssuedKey issued;
        System.runAs(admin) {
            issued = AgentGovAdminController.rotateApiKey(agent);
        }

        Assert.isTrue(issued.success, 'Refused: ' + issued.message);
        Assert.isTrue(issued.apiKey.startsWith(AgentGovConstants.API_KEY_PREFIX));
        Assert.areEqual(AgentGovRestAuth.hashKey(issued.apiKey), tripped().API_Key_Hash__c, 'Only the hash is stored');
        String details = adminRows()[0].Details__c;
        Assert.isTrue(details.contains(issued.apiKeyPrefix), details);
        Assert.isFalse(details.contains(issued.apiKey), 'The key itself is never written to the log');
    }

    @IsTest
    static void creditingABudgetLowersTodaysUsage() {
        User admin = administrator();
        Id agent = tripped().Id;
        AgentGov_Budget__c budget = budgetUsing(agent, 100, 0);

        AgentGovAdminController.ActionOutcome outcome;
        System.runAs(admin) {
            outcome = AgentGovAdminController.creditBudget(agent, AgentGovConstants.LIMIT_API_CALLS, 40);
        }

        Assert.isTrue(outcome.success, outcome.message);
        Assert.areEqual('Credited 40 API calls to today\'s budget.', outcome.message);
        Assert.areEqual(60, reload(budget).API_Calls_Consumed__c);
        List<AgentGov_Action_Log__c> audit = adminRows();
        Assert.areEqual(1, audit.size());
        Assert.areEqual(
            'Credited 40 API calls to today\'s budget. Status is now Normal. Done from the console.',
            audit[0].Details__c
        );
    }

    @IsTest
    static void creditingMoreThanWasUsedCreditsOnlyWhatWasUsed() {
        User admin = administrator();
        Id agent = tripped().Id;
        AgentGov_Budget__c budget = budgetUsing(agent, 30, 1);

        AgentGovAdminController.ActionOutcome apiCredit;
        AgentGovAdminController.ActionOutcome soqlCredit;
        System.runAs(admin) {
            apiCredit = AgentGovAdminController.creditBudget(agent, AgentGovConstants.LIMIT_API_CALLS, 40);
            soqlCredit = AgentGovAdminController.creditBudget(agent, AgentGovConstants.LIMIT_SOQL_QUERIES, 5);
        }

        Assert.isTrue(apiCredit.success, apiCredit.message);
        Assert.areEqual(
            'Credited 30 API calls to today\'s budget, bringing its API call usage to zero.',
            apiCredit.message
        );
        Assert.areEqual(
            'Credited 1 SOQL query to today\'s budget, bringing its SOQL query usage to zero.',
            soqlCredit.message
        );
        AgentGov_Budget__c after = reload(budget);
        Assert.areEqual(0, after.API_Calls_Consumed__c, 'Usage never goes below zero');
        Assert.areEqual(0, after.SOQL_Queries_Consumed__c, 'Usage never goes below zero');
        Set<String> audited = new Set<String>();
        for (AgentGov_Action_Log__c row : adminRows()) {
            audited.add(row.Details__c);
        }
        Assert.isTrue(
            audited.contains(
                'Credited 30 API calls to today\'s budget, bringing its API call usage to zero ' +
                '(a credit of 40 was requested). Status is now Normal. Done from the console.'
            ),
            String.join(new List<String>(audited), ' | ')
        );
        Assert.areEqual(2, audited.size(), 'Each credit is audited');
    }

    @IsTest
    static void creditingALimitWithNothingUsedTodayChangesNothing() {
        User admin = administrator();
        Id agent = tripped().Id;
        AgentGov_Budget__c budget = budgetUsing(agent, 30, 0);
        AgentGov_Registration__c fresh = AgentGovTestDataFactory.createRegistration('Fresh', 'Flow_Based', true);

        AgentGovAdminController.ActionOutcome soqlCredit;
        AgentGovAdminController.ActionOutcome freshCredit;
        System.runAs(admin) {
            soqlCredit = AgentGovAdminController.creditBudget(agent, AgentGovConstants.LIMIT_SOQL_QUERIES, 5);
            freshCredit = AgentGovAdminController.creditBudget(fresh.Id, AgentGovConstants.LIMIT_DML_OPERATIONS, 5);
        }

        Assert.isFalse(soqlCredit.success, 'Nothing was credited');
        Assert.areEqual('Nothing was credited: no SOQL queries have been used today.', soqlCredit.message);
        Assert.areEqual('Nothing was credited: no DML operations have been used today.', freshCredit.message);
        Assert.areEqual(30, reload(budget).API_Calls_Consumed__c, 'The budget is unchanged');
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM AgentGov_Budget__c WHERE Agent_Registration__c = :fresh.Id],
            'No budget row is left behind for an agent that had none'
        );
        Assert.areEqual(0, adminRows().size(), 'No audit row for a change that did not happen');
    }

    @IsTest
    static void aRefusedActionIsReportedAndLeavesNothingHalfDone() {
        User admin = administrator();
        AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
        settings.Max_Concurrent_Agents__c = 0;
        update settings;
        AgentGov_Registration__c idle = AgentGovTestDataFactory.createRegistration('Idle', 'Flow_Based', false);
        idle.Status__c = AgentGovConstants.STATUS_INACTIVE;
        insert idle;

        List<AgentGovAdminController.ActionOutcome> outcomes;
        System.runAs(admin) {
            outcomes = AgentGovAdminController.activateAgents(new List<Id>{ idle.Id });
        }

        Assert.isFalse(outcomes[0].success);
        Assert.areEqual(AgentGovConstants.ERR_MAX_CONCURRENT_AGENTS, outcomes[0].message);
        Assert.areEqual(AgentGovConstants.STATUS_INACTIVE, statusOf(idle.Id));
        Assert.areEqual(0, adminRows().size(), 'No audit row for a change that did not happen');
    }

    @IsTest
    static void aFailureAfterTheChangeRollsBackTheChangeAndItsAuditRow() {
        User admin = administrator();
        Id agent = tripped().Id;
        AgentGov_Budget__c budget = budgetUsing(agent, 100, 0);
        AgentGovAdminController.failureAfterAudit = new SimulatedFailureException(
            'Simulated failure after the audit rows were written.'
        );

        List<AgentGovAdminController.ActionOutcome> reset;
        AgentGovAdminController.ActionOutcome credit;
        System.runAs(admin) {
            reset = AgentGovAdminController.resetBreakers(new List<Id>{ agent });
            credit = AgentGovAdminController.creditBudget(agent, AgentGovConstants.LIMIT_API_CALLS, 40);
        }

        Assert.isFalse(reset[0].success, 'The reset is reported as failed');
        Assert.areEqual(
            'The circuit breakers could not be reset. The details are in the AgentGov action log.',
            reset[0].message
        );
        Assert.isFalse(credit.success, 'The credit is reported as failed');
        Assert.areEqual(
            'The budget could not be credited. The details are in the AgentGov action log.',
            credit.message
        );
        AgentGov_Registration__c after = tripped();
        Assert.areEqual(AgentGovConstants.CB_OPEN, after.Circuit_Breaker_State__c, 'The reset was rolled back');
        Assert.areEqual(AgentGovConstants.STATUS_BLOCKED, after.Status__c, 'The reactivation was rolled back');
        Assert.areEqual(100, reload(budget).API_Calls_Consumed__c, 'The credit was rolled back');
        Assert.areEqual(0, adminRows().size(), 'No audit row stands for a change that was rolled back');
        Set<String> causes = new Set<String>();
        for (AgentGov_Action_Log__c row : [
            SELECT Details__c, Error_Message__c
            FROM AgentGov_Action_Log__c
            WHERE Action_Type__c = :AgentGovConstants.ACTION_SYSTEM AND Status__c = :AgentGovConstants.ACTION_FAILURE
        ]) {
            Assert.isTrue(
                row.Error_Message__c.contains('Simulated failure after the audit rows were written.'),
                row.Error_Message__c
            );
            causes.add(row.Details__c);
        }
        Assert.areEqual(
            new Set<String>{ 'The circuit breakers could not be reset.', 'The budget could not be credited.' },
            causes,
            'Each failure is recorded with its cause'
        );
    }

    @IsTest
    static void endingASessionTerminatesItAndAuditsIt() {
        User admin = administrator();
        Id agent = tripped().Id;
        AgentGov_Session__c session = AgentGovTestDataFactory.createSession(agent, true);

        List<AgentGovAdminController.ActionOutcome> outcomes;
        System.runAs(admin) {
            outcomes = AgentGovAdminController.endSessions(new List<Id>{ session.Id });
        }

        Assert.isTrue(outcomes[0].success, outcomes[0].message);
        Assert.areEqual('Session ended.', outcomes[0].message);
        AgentGov_Session__c ended = [SELECT Status__c, End_Reason__c FROM AgentGov_Session__c WHERE Id = :session.Id];
        Assert.areEqual(AgentGovConstants.SESSION_TERMINATED, ended.Status__c);
        Assert.areEqual(AgentGovConstants.SESSION_END_ADMINISTRATOR, ended.End_Reason__c);
        Assert.areEqual(agent, adminRows()[0].Agent_Registration__c);
    }

    @IsTest
    static void endingASessionThatHadAlreadyEndedChangesNothing() {
        User admin = administrator();
        Id agent = tripped().Id;
        AgentGov_Session__c session = AgentGovTestDataFactory.createSession(agent, false);
        session.Status__c = AgentGovConstants.SESSION_COMPLETED;
        session.End_Reason__c = AgentGovConstants.SESSION_END_IDLE;
        insert session;

        List<AgentGovAdminController.ActionOutcome> outcomes;
        System.runAs(admin) {
            outcomes = AgentGovAdminController.endSessions(new List<Id>{ session.Id });
        }

        Assert.isTrue(outcomes[0].success, 'The session is already in the state the action asks for');
        Assert.areEqual('The session had already ended.', outcomes[0].message);
        AgentGov_Session__c after = [SELECT Status__c, End_Reason__c FROM AgentGov_Session__c WHERE Id = :session.Id];
        Assert.areEqual(AgentGovConstants.SESSION_COMPLETED, after.Status__c, 'The ended session is left as it was');
        Assert.areEqual(AgentGovConstants.SESSION_END_IDLE, after.End_Reason__c);
        Assert.areEqual(0, adminRows().size(), 'No audit row for a change that did not happen');
    }

    @IsTest
    static void schedulingJobsIsAuditedAndReflectedInTheSetupStatus() {
        User admin = administrator();
        AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
        settings.Session_Idle_Minutes__c = 15;
        update settings;

        AgentGovAdminController.ActionOutcome outcome;
        AgentGovAdminController.SetupStatus status;
        System.runAs(admin) {
            outcome = AgentGovAdminController.scheduleJobs();
            status = AgentGovAdminController.getSetupStatus();
        }

        Assert.isTrue(outcome.success, outcome.message);
        Assert.isTrue(outcome.message.contains('run as you'), outcome.message);
        Assert.isTrue(status.governanceEnabled);
        Assert.isTrue(status.realTimeEventsEnabled);
        Assert.areEqual(15, status.sessionIdleMinutes, 'A valid idle window is shown as it is set');
        Assert.areEqual(3, status.jobs.size());
        for (AgentGovJobScheduler.JobStatus job : status.jobs) {
            Assert.isTrue(job.scheduled, job.name + ' is scheduled');
        }
        Assert.isTrue(status.policyProblems.isEmpty(), String.join(status.policyProblems, '; '));
        List<AgentGov_Action_Log__c> audit = adminRows();
        Assert.areEqual(1, audit.size(), 'Scheduling the jobs is audited');
        Assert.isNull(audit[0].Agent_Registration__c, 'No single agent is concerned');
        Assert.areEqual('Background jobs scheduled from the console.', audit[0].Details__c);
        Assert.areEqual(admin.Id, audit[0].CreatedById, 'The person who acted is the row creator');
    }

    @IsTest
    static void theSetupStatusShowsTheIdleWindowInForceAndWhetherEventsAreOn() {
        User admin = administrator();
        AgentGov_Settings__c settings = AgentGov_Settings__c.getOrgDefaults();
        settings.Session_Idle_Minutes__c = 0;
        settings.Enable_Real_Time_Events__c = false;
        settings.Admin_Notification_Email__c = 'alerts@example.com';
        settings.Notify_Agent_Owners__c = true;
        update settings;

        AgentGovAdminController.SetupStatus status;
        System.runAs(admin) {
            status = AgentGovAdminController.getSetupStatus();
        }

        Assert.areEqual(
            AgentGovConstants.DEFAULT_SESSION_IDLE_MINUTES,
            status.sessionIdleMinutes,
            'A value outside 1 to 1440 is shown as the default the session tracker applies'
        );
        Assert.isFalse(status.realTimeEventsEnabled, 'Real-time events are reported as off');
        Assert.isTrue(status.adminEmailConfigured);
        Assert.isTrue(status.notifyAgentOwners);
    }

    @IsTest
    static void actionsOnRecordsTheUserCannotSeeAreReportedNotApplied() {
        User admin = administrator();
        Id agent = tripped().Id;
        Id missing = Id.valueOf(String.valueOf(agent).left(3) + '000000000000');

        AgentGovAdminController.IssuedKey issued;
        AgentGovAdminController.ActionOutcome credit;
        System.runAs(admin) {
            issued = AgentGovAdminController.rotateApiKey(missing);
            credit = AgentGovAdminController.creditBudget(missing, AgentGovConstants.LIMIT_API_CALLS, 5);
        }

        Assert.isFalse(issued.success);
        Assert.isNull(issued.apiKey, 'No key is issued');
        Assert.areEqual(AgentGovConstants.ERR_NO_RECORD_ACCESS, issued.message);
        Assert.isFalse(credit.success);
        Assert.areEqual(AgentGovConstants.ERR_NO_RECORD_ACCESS, credit.message);
        Assert.areEqual(0, adminRows().size());
    }

    @IsTest
    static void invalidCreditsAreRefusedBeforeAnythingChanges() {
        User admin = administrator();
        Id agent = tripped().Id;

        List<String> messages = new List<String>();
        System.runAs(admin) {
            for (Integer amount : new List<Integer>{ 0, null }) {
                try {
                    AgentGovAdminController.creditBudget(agent, AgentGovConstants.LIMIT_API_CALLS, amount);
                } catch (AuraHandledException e) {
                    messages.add(e.getMessage());
                }
            }
            try {
                AgentGovAdminController.creditBudget(agent, 'Tokens', 5);
            } catch (AuraHandledException e) {
                messages.add(e.getMessage());
            }
        }

        Assert.areEqual(3, messages.size());
        Assert.areEqual(AgentGovConstants.ERR_INVALID_CREDIT, messages[0]);
        Assert.areEqual(AgentGovConstants.ERR_INVALID_CREDIT, messages[1]);
        Assert.isTrue(messages[2].startsWith(AgentGovConstants.ERR_INVALID_LIMIT_TYPE), messages[2]);
        Assert.areEqual(0, adminRows().size(), 'No audit row');
        Assert.areEqual(0, [SELECT COUNT() FROM AgentGov_Budget__c], 'No budget row is created');
    }

    @IsTest
    static void selectionsMustBeNonEmptyAndBounded() {
        User admin = administrator();
        List<Id> tooMany = new List<Id>();
        Id agent = tripped().Id;
        String idPrefix = String.valueOf(agent).left(3);
        for (Integer i = 0; i <= AgentGovConstants.MAX_ADMIN_BATCH; i++) {
            tooMany.add(Id.valueOf(idPrefix + String.valueOf(i).leftPad(12, '0')));
        }

        List<String> messages = new List<String>();
        System.runAs(admin) {
            for (List<Id> selection : new List<List<Id>>{ new List<Id>(), tooMany }) {
                try {
                    AgentGovAdminController.resetBreakers(selection);
                } catch (AuraHandledException e) {
                    messages.add(e.getMessage());
                }
            }
        }

        Assert.areEqual(AgentGovConstants.ERR_NOTHING_SELECTED, messages[0]);
        Assert.isTrue(messages[1].contains(String.valueOf(AgentGovConstants.MAX_ADMIN_BATCH)), messages[1]);
    }

    private class SimulatedFailureException extends Exception {
    }
}
