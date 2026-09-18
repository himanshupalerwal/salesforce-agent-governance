/**
 * @description Tests for the Register Agent Action invocable, including its bulk behaviour.
 */
@IsTest
private class AgentGovRegisterActionTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Action Agent', 'Flow_Based', true);
        AgentGovTestDataFactory.createBudget(reg.Id, true);
    }

    private static AgentGovRegisterAction.Request request(Id registrationId, String actionType) {
        AgentGovRegisterAction.Request req = new AgentGovRegisterAction.Request();
        req.registrationId = registrationId;
        req.actionType = actionType;
        req.objectName = 'Account';
        req.recordId = '001000000000001AAA';
        return req;
    }

    @IsTest
    static void authorizedRequestConsumesBudgetAndLogs() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        Test.startTest();
        List<AgentGovRegisterAction.Result> results = AgentGovRegisterAction.registerAction(
            new List<AgentGovRegisterAction.Request>{ request(reg.Id, AgentGovConstants.ACTION_QUERY) }
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isTrue(results[0].authorized);
        Assert.areEqual(AgentGovConstants.BUDGET_NORMAL, results[0].budgetStatus);
        Assert.areEqual(
            1,
            [SELECT SOQL_Queries_Consumed__c FROM AgentGov_Budget__c WHERE Agent_Registration__c = :reg.Id]
            .SOQL_Queries_Consumed__c
        );
        Assert.areEqual(
            1,
            [
                SELECT COUNT()
                FROM AgentGov_Action_Log__c
                WHERE Agent_Registration__c = :reg.Id AND Status__c = :AgentGovConstants.ACTION_SUCCESS
            ]
        );
    }

    @IsTest
    static void disabledFrameworkBypassesGovernance() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        List<AgentGovRegisterAction.Result> results = AgentGovRegisterAction.registerAction(
            new List<AgentGovRegisterAction.Request>{ request(reg.Id, AgentGovConstants.ACTION_DELETE) }
        );

        Assert.isTrue(results[0].authorized);
    }

    @IsTest
    static void openBreakerDenies() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        reg.Cooldown_Until__c = DateTime.now().addHours(1);
        update reg;

        List<AgentGovRegisterAction.Result> results = AgentGovRegisterAction.registerAction(
            new List<AgentGovRegisterAction.Request>{ request(reg.Id, AgentGovConstants.ACTION_QUERY) }
        );

        Assert.isFalse(results[0].authorized);
        Assert.isTrue(results[0].denialReason.contains('Circuit breaker'));
    }

    @IsTest
    static void unknownAgentAndInvalidActionTypeAreDenied() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        Id unknownId = AgentGov_Registration__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';

        List<AgentGovRegisterAction.Result> results = AgentGovRegisterAction.registerAction(
            new List<AgentGovRegisterAction.Request>{
                request(unknownId, AgentGovConstants.ACTION_QUERY),
                request(reg.Id, 'Explode')
            }
        );

        Assert.isFalse(results[0].authorized);
        Assert.areEqual(AgentGovConstants.ERR_AGENT_NOT_FOUND, results[0].denialReason);
        Assert.isFalse(results[1].authorized);
        Assert.isTrue(results[1].denialReason.startsWith(AgentGovConstants.ERR_INVALID_ACTION_TYPE));
    }

    @IsTest
    static void anInvalidActionTypeIsStillAudited() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        Test.startTest();
        AgentGovRegisterAction.registerAction(new List<AgentGovRegisterAction.Request>{ request(reg.Id, 'Explode') });
        Test.getEventBus().deliver();
        Test.stopTest();

        // Every other denial branch writes an audit row. This one used to return silently,
        // leaving no record that the agent had attempted anything.
        //
        // The entry lands as a System row: 'Explode' is not in the Action_Type__c picklist, so
        // the database rejects the original and the handler re-inserts a row it fully
        // controls, carrying the rejected values in the details. That is the audit-preserving
        // path, and the point here is that something is recorded at all.
        List<AgentGov_Action_Log__c> logs = [
            SELECT Action_Type__c, Status__c, Details__c
            FROM AgentGov_Action_Log__c
        ];
        Assert.areEqual(1, logs.size(), 'The denial is recorded in the audit trail');
        Assert.areEqual(AgentGovConstants.ACTION_SYSTEM, logs[0].Action_Type__c);
        Assert.isTrue(logs[0].Details__c.contains('Explode'), 'The rejected action type is preserved in the entry');
        Assert.isTrue(
            logs[0].Details__c.contains(reg.Id),
            'The acting agent is preserved even though the lookup could not be reused'
        );
    }

    @IsTest
    static void exhaustedBudgetDeniesEveryRequestOfThatAgent() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        AgentGov_Budget__c budget = [SELECT Id FROM AgentGov_Budget__c WHERE Agent_Registration__c = :reg.Id];
        budget.DML_Operations_Consumed__c = 2999;
        update budget;

        List<AgentGovRegisterAction.Result> results = AgentGovRegisterAction.registerAction(
            new List<AgentGovRegisterAction.Request>{
                request(reg.Id, AgentGovConstants.ACTION_UPDATE),
                request(reg.Id, AgentGovConstants.ACTION_UPDATE)
            }
        );

        Assert.isFalse(results[0].authorized, 'Two updates together exceed the budget, so both are denied');
        Assert.isFalse(results[1].authorized);
        Assert.isTrue(results[0].denialReason.contains(AgentGovConstants.LIMIT_DML_OPERATIONS));
    }

    @IsTest
    static void aHalfOpenAgentGetsOneProbeNotOnePerRequest() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_HALF_OPEN;
        reg.Status__c = AgentGovConstants.STATUS_THROTTLED;
        reg.Half_Open_Probe_At__c = null;
        update reg;
        AgentGovSelector.clearCache();

        List<AgentGovRegisterAction.Request> requests = new List<AgentGovRegisterAction.Request>();
        for (Integer i = 0; i < 10; i++) {
            requests.add(request(reg.Id, AgentGovConstants.ACTION_QUERY));
        }

        Test.startTest();
        List<AgentGovRegisterAction.Result> results = AgentGovRegisterAction.registerAction(requests);
        Test.stopTest();

        // allowRequests returns one decision per agent. Reusing it for every request would
        // send the whole batch to a downstream the breaker had just declared unhealthy.
        Integer authorized = 0;
        for (AgentGovRegisterAction.Result r : results) {
            if (r.authorized == true) {
                authorized++;
            }
        }
        Assert.areEqual(1, authorized, 'Exactly one request is admitted as the probe');
        Assert.isTrue(
            results[1].denialReason.contains('Circuit breaker'),
            'The rest are refused like any other open breaker'
        );
    }

    @IsTest
    static void aClosedBreakerStillAdmitsTheWholeBatch() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        List<AgentGovRegisterAction.Request> requests = new List<AgentGovRegisterAction.Request>();
        for (Integer i = 0; i < 5; i++) {
            requests.add(request(reg.Id, AgentGovConstants.ACTION_QUERY));
        }

        Test.startTest();
        List<AgentGovRegisterAction.Result> results = AgentGovRegisterAction.registerAction(requests);
        Test.stopTest();

        for (Integer i = 0; i < 5; i++) {
            Assert.isTrue(results[i].authorized, 'A healthy agent is not rate-limited by the probe rule');
        }
    }

    @IsTest
    static void twoHundredRequestsStayWithinLimits() {
        List<AgentGov_Registration__c> agents = AgentGovTestDataFactory.createRegistrations(5, 'Flow_Based');
        List<AgentGovRegisterAction.Request> requests = new List<AgentGovRegisterAction.Request>();
        for (Integer i = 0; i < 200; i++) {
            requests.add(request(agents[Math.mod(i, 5)].Id, AgentGovConstants.ACTION_QUERY));
        }

        Test.startTest();
        List<AgentGovRegisterAction.Result> results = AgentGovRegisterAction.registerAction(requests);
        Integer queries = Limits.getQueries();
        Integer dml = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(200, results.size());
        for (Integer i = 0; i < 200; i++) {
            Assert.isTrue(results[i].authorized, 'Request ' + i + ' should be authorized: ' + results[i].denialReason);
        }
        Assert.isTrue(queries < 12, 'Bulk path used ' + queries + ' queries');
        Assert.isTrue(dml < 10, 'Bulk path used ' + dml + ' DML statements');
        Assert.areEqual(
            40,
            [SELECT SOQL_Queries_Consumed__c FROM AgentGov_Budget__c WHERE Agent_Registration__c = :agents[0].Id]
            .SOQL_Queries_Consumed__c
        );
    }
}
