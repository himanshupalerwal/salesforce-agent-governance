/**
 * @description Tests for the console's administrative actions: the permission matrix, the
 *              audit row every action writes, key rotation that never records the key, and
 *              failures that roll the change back instead of half-applying it.
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
        User admin = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Admin' });
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
        Assert.areEqual(AgentGovConstants.STATUS_INACTIVE, tripped().Status__c);
        Assert.areEqual(AgentGovConstants.ERR_MANAGE_KEYS_PERMISSION, keyMessage);
    }

    @IsTest
    static void aRotatedKeyIsReturnedOnceAndOnlyItsPrefixIsAudited() {
        User admin = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Admin' });
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
        User admin = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Admin' });
        Id agent = tripped().Id;
        AgentGov_Budget__c budget = AgentGovTestDataFactory.createBudget(agent, false);
        budget.API_Calls_Consumed__c = 100;
        insert budget;

        AgentGovAdminController.ActionOutcome outcome;
        System.runAs(admin) {
            outcome = AgentGovAdminController.creditBudget(agent, AgentGovConstants.LIMIT_API_CALLS, 40);
        }

        Assert.isTrue(outcome.success, outcome.message);
        Assert.areEqual(
            60,
            [SELECT API_Calls_Consumed__c FROM AgentGov_Budget__c WHERE Id = :budget.Id].API_Calls_Consumed__c
        );
        Assert.areEqual(1, adminRows().size());
    }

    @IsTest
    static void aRefusedActionIsReportedAndLeavesNothingHalfDone() {
        User admin = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Admin' });
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
        Assert.areEqual(
            AgentGovConstants.STATUS_INACTIVE,
            [SELECT Status__c FROM AgentGov_Registration__c WHERE Id = :idle.Id].Status__c
        );
        Assert.areEqual(0, adminRows().size(), 'No audit row for a change that did not happen');
    }

    @IsTest
    static void endingASessionTerminatesItAndAuditsIt() {
        User admin = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Admin' });
        Id agent = tripped().Id;
        AgentGov_Session__c session = AgentGovTestDataFactory.createSession(agent, true);

        List<AgentGovAdminController.ActionOutcome> outcomes;
        System.runAs(admin) {
            outcomes = AgentGovAdminController.endSessions(new List<Id>{ session.Id });
        }

        Assert.isTrue(outcomes[0].success, outcomes[0].message);
        AgentGov_Session__c ended = [SELECT Status__c, End_Reason__c FROM AgentGov_Session__c WHERE Id = :session.Id];
        Assert.areEqual(AgentGovConstants.SESSION_TERMINATED, ended.Status__c);
        Assert.areEqual(AgentGovConstants.SESSION_END_ADMINISTRATOR, ended.End_Reason__c);
        Assert.areEqual(agent, adminRows()[0].Agent_Registration__c);
    }

    @IsTest
    static void schedulingJobsIsReflectedInTheSetupStatus() {
        User admin = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Admin' });

        AgentGovAdminController.ActionOutcome outcome;
        AgentGovAdminController.SetupStatus status;
        System.runAs(admin) {
            outcome = AgentGovAdminController.scheduleJobs();
            status = AgentGovAdminController.getSetupStatus();
        }

        Assert.isTrue(outcome.success, outcome.message);
        Assert.isTrue(status.governanceEnabled);
        Assert.areEqual(3, status.jobs.size());
        for (AgentGovJobScheduler.JobStatus job : status.jobs) {
            Assert.isTrue(job.scheduled, job.name + ' is scheduled');
        }
        Assert.isTrue(status.policyProblems.isEmpty(), String.join(status.policyProblems, '; '));
    }

    @IsTest
    static void actionsOnRecordsTheUserCannotSeeAreReportedNotApplied() {
        User admin = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Admin' });
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
        User admin = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Admin' });
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
        Assert.isTrue(messages[2].startsWith(AgentGovConstants.ERR_INVALID_LIMIT_TYPE), messages[2]);
    }

    @IsTest
    static void selectionsMustBeNonEmptyAndBounded() {
        User admin = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Admin' });
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
}
