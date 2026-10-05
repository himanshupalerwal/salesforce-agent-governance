/**
 * @description Tests for AgentGovTriggerHandler: event-backed logging, fallbacks, rejected
 *              entries, alert emails, and budget key population.
 */
@IsTest
private class AgentGovTriggerHandlerTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    private static List<AgentGov_Action_Log__c> logsFor(Id registrationId) {
        return [
            SELECT Action_Type__c, Status__c, Details__c, Error_Message__c
            FROM AgentGov_Action_Log__c
            WHERE Agent_Registration__c = :registrationId
        ];
    }

    @IsTest
    static void logActionPersistsThroughPlatformEvent() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Handler Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovTriggerHandler.logAction(
            reg.Id,
            AgentGovConstants.ACTION_QUERY,
            'Account',
            '001000000000001',
            AgentGovConstants.ACTION_SUCCESS,
            '{"test": true}'
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        List<AgentGov_Action_Log__c> logs = logsFor(reg.Id);
        Assert.areEqual(1, logs.size());
        Assert.areEqual(AgentGovConstants.ACTION_QUERY, logs[0].Action_Type__c);
        Assert.areEqual('{"test": true}', logs[0].Details__c);
    }

    @IsTest
    static void auditingContinuesWhenTheFrameworkIsDisabled() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Handler Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovTriggerHandler.logAction(
            reg.Id,
            AgentGovConstants.ACTION_QUERY,
            'Account',
            null,
            AgentGovConstants.ACTION_SUCCESS,
            null
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        // Is_Enabled__c suspends enforcement, not the audit trail. Activity that happens while
        // governance is switched off is precisely what an administrator needs recorded.
        Assert.areEqual(1, logsFor(reg.Id).size(), 'Actions are still audited while governance is disabled');
    }

    @IsTest
    static void aRefusedPublishStillWritesTheAuditRows() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Handler Agent', 'Agentforce', true);
        AgentGovDml.simulatePublishRefusal = true;

        Test.startTest();
        AgentGovTriggerHandler.logAction(
            reg.Id,
            AgentGovConstants.ACTION_QUERY,
            'Account',
            null,
            AgentGovConstants.ACTION_SUCCESS,
            null
        );
        Test.stopTest();

        // The user an agent runs as is deliberately not granted publish access, because on a
        // platform event Create cannot be granted without Read and Read is subscribe access.
        // The trail must survive that refusal rather than aborting the governed transaction.
        Assert.areEqual(1, logsFor(reg.Id).size(), 'A refused publish falls back to a direct insert');
    }

    @IsTest
    static void aRefusedAlertPublishIsRecordedNotThrown() {
        AgentGovDml.simulatePublishRefusal = true;

        Test.startTest();
        AgentGovTriggerHandler.publishAlerts(
            new List<AgentGov_Alert__e>{
                new AgentGov_Alert__e(
                    Alert_Type__c = AgentGovConstants.ALERT_WARNING,
                    Limit_Type__c = AgentGovConstants.LIMIT_API_CALLS,
                    Timestamp__c = DateTime.now()
                )
            }
        );
        Test.stopTest();

        Assert.areEqual(
            1,
            [
                SELECT COUNT()
                FROM AgentGov_Action_Log__c
                WHERE Action_Type__c = :AgentGovConstants.ACTION_SYSTEM
            ],
            'The refusal is recorded as a framework event instead of aborting the transaction'
        );
    }

    @IsTest
    static void anActionLoggedByAUserWhoCannotPublishIsStillWritten() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Handler Agent', 'Agentforce', true);
        User agentUser = AgentGovTestDataFactory.createRestrictedUser(new List<String>());

        Test.startTest();
        System.runAs(agentUser) {
            AgentGovTriggerHandler.logAction(
                reg.Id,
                AgentGovConstants.ACTION_QUERY,
                'Account',
                null,
                AgentGovConstants.ACTION_SUCCESS,
                null
            );
        }
        Test.getEventBus().deliver();
        Test.stopTest();

        // The platform refuses this user's publish with a failed result, not an exception, and
        // the row is then written directly.
        Assert.areEqual(1, logsFor(reg.Id).size(), 'The refused publish falls back to a direct insert');
    }

    @IsTest
    static void alertsAUserCannotPublishAreStillRecordedAndDelivered() {
        AgentGov_Registration__c agent = AgentGovTestDataFactory.createRegistration('Tripped', 'Agentforce', true);
        User agentUser = AgentGovTestDataFactory.createRestrictedUser(new List<String>());

        Test.startTest();
        System.runAs(agentUser) {
            AgentGovTriggerHandler.publishAlerts(
                new List<AgentGov_Alert__e>{
                    new AgentGov_Alert__e(
                        Agent_Id__c = agent.Id,
                        Agent_Name__c = 'Tripped',
                        Alert_Type__c = AgentGovConstants.ALERT_BLOCK,
                        Limit_Type__c = AgentGovConstants.ALERT_LIMIT_CIRCUIT_BREAKER,
                        Current_Usage__c = 3,
                        Budget_Allocated__c = 3,
                        Usage_Percentage__c = 100,
                        Timestamp__c = DateTime.now()
                    )
                }
            );
        }
        Test.getEventBus().deliver();
        Test.stopTest();

        // The alert trigger never sees an alert whose publish was refused, so the alert is
        // delivered directly: recorded here, and emailed to anyone configured to receive it.
        AgentGov_Action_Log__c recorded = [
            SELECT Details__c
            FROM AgentGov_Action_Log__c
            WHERE Agent_Registration__c = :agent.Id AND Action_Type__c = :AgentGovConstants.ACTION_ALERT
        ];
        Assert.areEqual('Breaker open: 3 failures reached the threshold of 3.', recorded.Details__c);
        List<AgentGov_Action_Log__c> notes = [
            SELECT Details__c
            FROM AgentGov_Action_Log__c
            WHERE Action_Type__c = :AgentGovConstants.ACTION_SYSTEM
        ];
        Assert.areEqual(1, notes.size(), 'The refusal is recorded once');
        Assert.isTrue(notes[0].Details__c.contains('delivering 1 alert(s) directly'), notes[0].Details__c);
    }

    @IsTest
    static void directInsertWhenEventsDisabled() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Enable_Real_Time_Events__c = false;
        update settings;
        AgentGovSelector.clearCache();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Handler Agent', 'Agentforce', true);

        AgentGovTriggerHandler.logAction(
            reg.Id,
            AgentGovConstants.ACTION_CREATE,
            'Contact',
            '003000000000001',
            AgentGovConstants.ACTION_SUCCESS,
            null
        );

        Assert.areEqual(1, logsFor(reg.Id).size(), 'Rows are inserted directly without an event round trip');
    }

    @IsTest
    static void bulkEventsBecomeRows() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Handler Agent', 'Agentforce', true);
        List<AgentGov_Action_Event__e> events = new List<AgentGov_Action_Event__e>();
        for (Integer i = 0; i < 3; i++) {
            events.add(
                AgentGovTriggerHandler.buildEvent(
                    reg.Id,
                    'Handler Agent',
                    AgentGovConstants.ACTION_UPDATE,
                    'Account',
                    null,
                    AgentGovConstants.ACTION_SUCCESS,
                    'row ' + i
                )
            );
        }

        Test.startTest();
        AgentGovTriggerHandler.logActions(events);
        AgentGovTriggerHandler.logActions(new List<AgentGov_Action_Event__e>());
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(3, logsFor(reg.Id).size());
    }

    @IsTest
    static void rejectedEntryIsKeptAsSystemRow() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Handler Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovTriggerHandler.logAction(
            reg.Id,
            'NotAPicklistValue',
            'Account',
            null,
            AgentGovConstants.ACTION_SUCCESS,
            'original details'
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        List<AgentGov_Action_Log__c> logs = [
            SELECT Agent_Registration__c, Action_Type__c, Status__c, Details__c, Error_Message__c
            FROM AgentGov_Action_Log__c
        ];
        Assert.areEqual(1, logs.size(), 'The entry is not lost');
        Assert.areEqual(AgentGovConstants.ACTION_SYSTEM, logs[0].Action_Type__c);
        Assert.areEqual(AgentGovConstants.ACTION_FAILURE, logs[0].Status__c);
        Assert.isNull(
            logs[0].Agent_Registration__c,
            'The replacement row keeps only values the framework controls; the original lookup may itself be the reason for the rejection'
        );
        Assert.isTrue(logs[0].Details__c.contains(reg.Id), 'The original agent is preserved in the details');
        Assert.isTrue(logs[0].Details__c.contains('NotAPicklistValue'), 'The original action type is preserved');
        Assert.isTrue(logs[0].Details__c.contains('original details'));
        Assert.isTrue(logs[0].Error_Message__c.contains('Log entry rejected'));
    }

    @IsTest
    static void anActionWithNoAgentIsStillLogged() {
        Test.startTest();
        AgentGovTriggerHandler.logActions(
            new List<AgentGov_Action_Event__e>{
                AgentGovTriggerHandler.buildEvent(
                    null,
                    'Ghost',
                    AgentGovConstants.ACTION_QUERY,
                    'Account',
                    null,
                    AgentGovConstants.ACTION_SUCCESS,
                    null
                )
            }
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM AgentGov_Action_Log__c WHERE Agent_Registration__c = NULL]);
    }

    @IsTest
    static void alertsAreEmailedToAdministrator() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Admin_Notification_Email__c = 'ops@example.com';
        update settings;
        AgentGovSelector.clearCache();
        List<AgentGov_Alert__e> alerts = new List<AgentGov_Alert__e>{
            new AgentGov_Alert__e(
                Agent_Name__c = 'Alert Agent',
                Alert_Type__c = AgentGovConstants.ALERT_WARNING,
                Limit_Type__c = AgentGovConstants.LIMIT_API_CALLS,
                Current_Usage__c = 8000,
                Budget_Allocated__c = 10000,
                Usage_Percentage__c = 80,
                Timestamp__c = DateTime.now()
            )
        };

        Boolean canSend = orgCanSendEmail(1);

        // The event trigger runs in its own execution context, so the handler is exercised
        // directly to observe the email invocation; publishing is asserted separately.
        Test.startTest();
        List<Database.SaveResult> published = AgentGovDml.publishEvents(alerts);
        AgentGovTriggerHandler.handleAlerts(alerts);
        Integer emails = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.isTrue(published[0].isSuccess(), 'The alert is accepted by the event bus');
        Assert.areEqual(1, emails, 'One email is sent per delivered batch');
        assertDelivery(canSend);
    }

    @IsTest
    static void deliveredAlertsAreRecordedAsHistoryEvenWithoutARecipient() {
        AgentGov_Registration__c agent = AgentGovTestDataFactory.createRegistration('History', 'Agentforce', true);

        Test.startTest();
        AgentGovTriggerHandler.handleAlerts(
            new List<AgentGov_Alert__e>{
                new AgentGov_Alert__e(
                    Agent_Id__c = agent.Id,
                    Agent_Name__c = 'History',
                    Alert_Type__c = AgentGovConstants.ALERT_THROTTLE,
                    Limit_Type__c = AgentGovConstants.LIMIT_API_CALLS,
                    Usage_Percentage__c = 90,
                    Timestamp__c = DateTime.now()
                )
            }
        );
        Test.stopTest();

        AgentGov_Action_Log__c row = [
            SELECT Action_Type__c, Details__c
            FROM AgentGov_Action_Log__c
            WHERE Agent_Registration__c = :agent.Id
        ];
        Assert.areEqual(AgentGovConstants.ACTION_ALERT, row.Action_Type__c);
        Assert.areEqual('Throttled: API calls at 90% of today\'s budget.', row.Details__c);
    }

    @IsTest
    static void alertRowsSayWhatHappenedInWords() {
        AgentGov_Registration__c agent = AgentGovTestDataFactory.createRegistration('Worded', 'Agentforce', true);

        Test.startTest();
        AgentGovTriggerHandler.handleAlerts(
            new List<AgentGov_Alert__e>{
                new AgentGov_Alert__e(
                    Agent_Id__c = agent.Id,
                    Agent_Name__c = 'Worded',
                    Alert_Type__c = AgentGovConstants.ALERT_BLOCK,
                    Limit_Type__c = AgentGovConstants.LIMIT_SOQL_QUERIES,
                    Usage_Percentage__c = 95.4,
                    Current_Usage__c = 19,
                    Budget_Allocated__c = 20,
                    Timestamp__c = DateTime.now()
                ),
                new AgentGov_Alert__e(
                    Agent_Id__c = agent.Id,
                    Agent_Name__c = 'Worded',
                    Alert_Type__c = AgentGovConstants.ALERT_BLOCK,
                    Limit_Type__c = AgentGovConstants.ALERT_LIMIT_CIRCUIT_BREAKER,
                    Usage_Percentage__c = 100,
                    Current_Usage__c = 3,
                    Budget_Allocated__c = 3,
                    Timestamp__c = DateTime.now()
                )
            }
        );
        Test.stopTest();

        Set<String> details = new Set<String>();
        for (AgentGov_Action_Log__c row : [
            SELECT Details__c
            FROM AgentGov_Action_Log__c
            WHERE Agent_Registration__c = :agent.Id AND Action_Type__c = :AgentGovConstants.ACTION_ALERT
        ]) {
            details.add(row.Details__c);
        }
        Assert.isTrue(
            details.contains('Blocked: SOQL queries at 95% of today\'s budget (19 of 20).'),
            'Budget alert: ' + details
        );
        Assert.isTrue(
            details.contains('Breaker open: 3 failures reached the threshold of 3.'),
            'Breaker alert: ' + details
        );
    }

    @IsTest
    static void ownersAreEmailedAboutTheirOwnAgentsWhenEnabled() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Admin_Notification_Email__c = 'ops@example.com';
        settings.Notify_Agent_Owners__c = true;
        update settings;
        AgentGovSelector.clearCache();
        List<AgentGov_Registration__c> agents = AgentGovTestDataFactory.createRegistrations(2, 'Agentforce');
        agents[1].Owner_Email__c = 'second-owner@example.com';
        update agents;
        List<AgentGov_Alert__e> alerts = new List<AgentGov_Alert__e>();
        for (AgentGov_Registration__c agent : agents) {
            alerts.add(
                new AgentGov_Alert__e(
                    Agent_Id__c = agent.Id,
                    Agent_Name__c = agent.Agent_Name__c,
                    Alert_Type__c = AgentGovConstants.ALERT_WARNING,
                    Limit_Type__c = AgentGovConstants.LIMIT_API_CALLS,
                    Timestamp__c = DateTime.now()
                )
            );
        }

        Boolean canSend = orgCanSendEmail(3);

        Test.startTest();
        AgentGovTriggerHandler.handleAlerts(alerts);
        Integer emails = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(1, emails, 'The administrator and both owners are emailed in one send');
        Map<String, String> bodyByRecipient = new Map<String, String>();
        for (Messaging.SingleEmailMessage message : AgentGovTriggerHandler.sentAlertMessages) {
            Assert.areEqual(1, message.getToAddresses().size(), 'Each message has a single recipient');
            bodyByRecipient.put(message.getToAddresses()[0], message.getPlainTextBody());
        }
        Assert.areEqual(
            new Set<String>{ 'ops@example.com', 'agentgov-test@example.com', 'second-owner@example.com' },
            bodyByRecipient.keySet(),
            'The administrator and each owner get a message'
        );
        String first = agents[0].Agent_Name__c;
        String second = agents[1].Agent_Name__c;
        String adminBody = bodyByRecipient.get('ops@example.com');
        Assert.isTrue(
            adminBody.contains(first) && adminBody.contains(second),
            'The administrator hears about both: ' + adminBody
        );
        String firstOwnerBody = bodyByRecipient.get('agentgov-test@example.com');
        Assert.isTrue(firstOwnerBody.contains(first), firstOwnerBody);
        Assert.isFalse(
            firstOwnerBody.contains(second),
            'An owner hears only about their own agents: ' + firstOwnerBody
        );
        String secondOwnerBody = bodyByRecipient.get('second-owner@example.com');
        Assert.isTrue(secondOwnerBody.contains(second), secondOwnerBody);
        Assert.isFalse(
            secondOwnerBody.contains(first),
            'An owner hears only about their own agents: ' + secondOwnerBody
        );
        assertDelivery(canSend);
    }

    // An org that has used its daily email allowance, as a busy sandbox or scratch org can,
    // refuses every send, tests included. The tests then prove the other half of the contract:
    // the refused send is recorded rather than lost.
    private static Boolean orgCanSendEmail(Integer emails) {
        try {
            Messaging.reserveSingleEmailCapacity(emails);
            return true;
        } catch (System.HandledException e) {
            return false;
        }
    }

    private static void assertDelivery(Boolean canSend) {
        Integer failures = [
            SELECT COUNT()
            FROM AgentGov_Action_Log__c
            WHERE Action_Type__c = :AgentGovConstants.ACTION_SYSTEM
        ];
        if (canSend) {
            Assert.areEqual(0, failures, 'No delivery failure was recorded');
        } else {
            Assert.isTrue(failures > 0, 'The send the org refused was recorded as a delivery failure');
        }
    }

    @IsTest
    static void noEmailWithoutRecipient() {
        Test.startTest();
        AgentGovTriggerHandler.handleAlerts(
            new List<AgentGov_Alert__e>{
                new AgentGov_Alert__e(Agent_Name__c = 'Alert Agent', Alert_Type__c = AgentGovConstants.ALERT_BLOCK)
            }
        );
        Integer emails = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(0, emails);
    }

    @IsTest
    static void budgetKeyIsPopulatedByTrigger() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Key Agent', 'Agentforce', true);
        AgentGov_Budget__c budget = AgentGovTestDataFactory.createBudget(reg.Id, true);

        AgentGov_Budget__c stored = [SELECT Budget_Key__c FROM AgentGov_Budget__c WHERE Id = :budget.Id];
        Assert.areEqual(
            AgentGovBudgetManager.buildBudgetKey(reg.Id, AgentGovBudgetManager.budgetDate()),
            stored.Budget_Key__c
        );
    }

    @IsTest
    static void frameworkEventsAreRecordedAsSystemRows() {
        AgentGovTriggerHandler.recordFrameworkEvent(
            null,
            AgentGovConstants.ACTION_FAILURE,
            'something happened',
            'detail'
        );

        List<AgentGov_Action_Log__c> rows = [SELECT Action_Type__c, Status__c, Details__c FROM AgentGov_Action_Log__c];
        Assert.areEqual(1, rows.size());
        Assert.areEqual(AgentGovConstants.ACTION_SYSTEM, rows[0].Action_Type__c);
        Assert.areEqual('something happened', rows[0].Details__c);
    }

    @IsTest
    static void agentIdOfAnotherObjectTypeIsNotUsedAsLookup() {
        Account account = new Account(Name = 'Not an agent');
        insert account;

        Test.startTest();
        AgentGovTriggerHandler.logActions(
            new List<AgentGov_Action_Event__e>{
                AgentGovTriggerHandler.buildEvent(
                    account.Id,
                    'Impostor',
                    AgentGovConstants.ACTION_QUERY,
                    'Account',
                    null,
                    AgentGovConstants.ACTION_SUCCESS,
                    null
                )
            }
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        AgentGov_Action_Log__c entry = [SELECT Agent_Registration__c, Details__c FROM AgentGov_Action_Log__c LIMIT 1];
        Assert.isNull(entry.Agent_Registration__c);
        Assert.isTrue(entry.Details__c.contains('Unrecognised agent Id'));
    }

    @IsTest
    static void anActionForAnUnknownRegistrationIsStillLogged() {
        Id unknownId = AgentGov_Registration__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';

        Test.startTest();
        AgentGovTriggerHandler.logAction(
            unknownId,
            AgentGovConstants.ACTION_QUERY,
            'Account',
            null,
            AgentGovConstants.ACTION_SUCCESS,
            null
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM AgentGov_Action_Log__c WHERE Agent_Registration__c = NULL]);
    }

    @IsTest
    static void alertEmailBodyListsEveryAlert() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Admin_Notification_Email__c = 'ops@example.com';
        update settings;
        AgentGovSelector.clearCache();
        List<AgentGov_Alert__e> alerts = new List<AgentGov_Alert__e>();
        for (Integer i = 0; i < 3; i++) {
            alerts.add(
                new AgentGov_Alert__e(
                    Agent_Name__c = 'Agent ' + i,
                    Alert_Type__c = AgentGovConstants.ALERT_BLOCK,
                    Limit_Type__c = AgentGovConstants.LIMIT_DML_OPERATIONS,
                    Current_Usage__c = 3000,
                    Budget_Allocated__c = 3000,
                    Usage_Percentage__c = 100,
                    Timestamp__c = DateTime.now()
                )
            );
        }

        Test.startTest();
        AgentGovTriggerHandler.handleAlerts(alerts);
        Integer emails = Limits.getEmailInvocations();
        AgentGovTriggerHandler.handleAlerts(new List<AgentGov_Alert__e>());
        Test.stopTest();

        Assert.areEqual(1, emails, 'A batch of alerts produces a single email');
        Assert.areEqual(1, AgentGovTriggerHandler.sentAlertMessages.size(), 'One message, to the administrator');
        Messaging.SingleEmailMessage message = AgentGovTriggerHandler.sentAlertMessages[0];
        Assert.areEqual('AgentGov: 3 agent alerts', message.getSubject());
        String body = message.getPlainTextBody();
        for (AgentGov_Alert__e alert : alerts) {
            Assert.isTrue(
                body.contains(
                    alert.Agent_Name__c + ' - Blocked: DML operations at 100% of today\'s budget (3000 of 3000).'
                ),
                'Every alert is listed: ' + body
            );
        }
    }

    @IsTest
    static void alertEmailIsSkippedWhenTheEmailLimitIsReached() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Admin_Notification_Email__c = 'ops@example.com';
        update settings;
        AgentGovSelector.clearCache();
        List<AgentGov_Alert__e> alerts = new List<AgentGov_Alert__e>{
            new AgentGov_Alert__e(Agent_Name__c = 'Agent', Alert_Type__c = AgentGovConstants.ALERT_BLOCK)
        };

        Test.startTest();
        // Exhaust the transaction's email allowance, then confirm the handler records the
        // skip instead of throwing.
        while (Limits.getEmailInvocations() < Limits.getLimitEmailInvocations()) {
            Messaging.SingleEmailMessage filler = new Messaging.SingleEmailMessage();
            filler.setToAddresses(new List<String>{ 'filler@example.com' });
            filler.setSubject('filler');
            filler.setPlainTextBody('filler');
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ filler }, false);
        }
        AgentGovTriggerHandler.handleAlerts(alerts);
        Test.stopTest();

        AgentGov_Action_Log__c entry = [
            SELECT Details__c
            FROM AgentGov_Action_Log__c
            WHERE Action_Type__c = :AgentGovConstants.ACTION_SYSTEM
            LIMIT 1
        ];
        Assert.isTrue(entry.Details__c.contains('email limit'), entry.Details__c);
    }

    @IsTest
    static void alertsAreNotPublishedWhenEventsAreDisabled() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Enable_Real_Time_Events__c = false;
        settings.Admin_Notification_Email__c = 'ops@example.com';
        update settings;
        AgentGovSelector.clearCache();

        Test.startTest();
        AgentGovTriggerHandler.publishAlerts(
            new List<AgentGov_Alert__e>{
                new AgentGov_Alert__e(Agent_Name__c = 'Agent', Alert_Type__c = AgentGovConstants.ALERT_WARNING)
            }
        );
        AgentGovTriggerHandler.publishAlerts(null);
        Integer publishes = Limits.getDmlStatements();
        Test.getEventBus().deliver();
        Integer emails = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(0, publishes, 'Nothing is published when real-time events are disabled');
        Assert.areEqual(0, emails, 'And no alert email is sent');
    }

    @IsTest
    static void budgetKeysAreOnlySetWhenBothPartsArePresent() {
        AgentGov_Budget__c incomplete = new AgentGov_Budget__c(Budget_Date__c = AgentGovBudgetManager.budgetDate());

        AgentGovTriggerHandler.populateBudgetKeys(new List<AgentGov_Budget__c>{ incomplete });

        Assert.isNull(incomplete.Budget_Key__c, 'A budget without an agent cannot have a key');
    }

    @IsTest
    static void aRefusedAlertPublishStillEmailsTheAdministrator() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Admin_Notification_Email__c = 'agentgov-alerts@example.com';
        update settings;
        AgentGovSelector.clearCache();
        AgentGovDml.simulatePublishRefusal = true;

        Test.startTest();
        AgentGovTriggerHandler.publishAlerts(
            new List<AgentGov_Alert__e>{
                new AgentGov_Alert__e(
                    Alert_Type__c = AgentGovConstants.ALERT_BLOCK,
                    Limit_Type__c = AgentGovConstants.LIMIT_API_CALLS,
                    Agent_Name__c = 'Refused Publish Agent',
                    Timestamp__c = DateTime.now()
                )
            }
        );
        Integer emails = Limits.getEmailInvocations();
        Test.stopTest();

        // The agent user cannot publish, so the alert trigger never fires. Without a direct
        // send, a budget or breaker alert raised on a REST call would reach nobody.
        Assert.areEqual(1, emails, 'The alert is emailed directly when the publish is refused');
    }

    @IsTest
    static void frameworkEventsAreWrittenInOneStatement() {
        List<AgentGov_Action_Log__c> notes = new List<AgentGov_Action_Log__c>();
        for (Integer i = 0; i < 20; i++) {
            notes.add(
                AgentGovTriggerHandler.buildFrameworkEvent(null, AgentGovConstants.ACTION_FAILURE, 'note ' + i, null)
            );
        }

        Test.startTest();
        Integer before = Limits.getDmlStatements();
        AgentGovTriggerHandler.recordFrameworkEvents(notes);
        Integer used = Limits.getDmlStatements() - before;
        Test.stopTest();

        // Reporting each failure separately meant one DML per failure, which exhausted the
        // statement limit when a whole batch of sessions failed at once.
        Assert.areEqual(1, used, 'Twenty notes cost one DML statement');
        Assert.areEqual(20, [SELECT COUNT() FROM AgentGov_Action_Log__c], 'All notes are written');
    }
}
