/**
 * @description Tests for AgentGovBudgetManager: consumption, thresholds, persistence of
 *              overage, idempotent budget creation, credits, and bulk behaviour.
 */
@IsTest
private class AgentGovBudgetManagerTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'Budget Test Agent',
            'Agentforce',
            true
        );
        AgentGovTestDataFactory.createBudget(reg.Id, true);
    }

    private static AgentGov_Registration__c primaryAgent() {
        return [SELECT Id FROM AgentGov_Registration__c WHERE Agent_Name__c = 'Budget Test Agent' LIMIT 1];
    }

    private static AgentGov_Budget__c todaysBudget(Id registrationId) {
        return [
            SELECT
                Id,
                Budget_Key__c,
                Budget_Status__c,
                API_Calls_Consumed__c,
                SOQL_Queries_Consumed__c,
                DML_Operations_Consumed__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c = :registrationId AND Budget_Date__c = TODAY
        ];
    }

    private static void useDefaultThresholds() {
        AgentGovBudgetManager.Thresholds thresholds = new AgentGovBudgetManager.Thresholds();
        thresholds.warning = 80;
        thresholds.throttle = 90;
        thresholds.block = 95;
        for (String limitType : AgentGovConstants.VALID_LIMIT_TYPES) {
            AgentGovBudgetManager.thresholdOverrides.put(limitType, thresholds);
        }
    }

    @IsTest
    static void checkBudgetReturnsFullAllocation() {
        Test.startTest();
        AgentGovBudgetManager.BudgetResult result = AgentGovBudgetManager.checkBudget(primaryAgent().Id);
        Test.stopTest();

        Assert.isTrue(result.allowed, 'A fresh budget allows requests');
        Assert.areEqual(AgentGovConstants.BUDGET_NORMAL, result.budgetStatus);
        Assert.areEqual(10000, result.apiCallsRemaining);
    }

    @IsTest
    static void checkBudgetRejectsNullId() {
        try {
            AgentGovBudgetManager.checkBudget(null);
            Assert.fail('A null Id must be rejected');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
        }
    }

    @IsTest
    static void consumeBudgetDeductsEachLimitType() {
        Id agentId = primaryAgent().Id;

        Test.startTest();
        AgentGovBudgetManager.BudgetResult api = AgentGovBudgetManager.consumeBudget(
            agentId,
            AgentGovConstants.LIMIT_API_CALLS,
            100
        );
        AgentGovBudgetManager.BudgetResult soql = AgentGovBudgetManager.consumeBudget(
            agentId,
            AgentGovConstants.LIMIT_SOQL_QUERIES,
            50
        );
        AgentGovBudgetManager.BudgetResult dml = AgentGovBudgetManager.consumeBudget(
            agentId,
            AgentGovConstants.LIMIT_DML_OPERATIONS,
            30
        );
        Test.stopTest();

        Assert.areEqual(9900, api.apiCallsRemaining);
        Assert.areEqual(4950, soql.soqlQueriesRemaining);
        Assert.areEqual(2970, dml.dmlOperationsRemaining);
        AgentGov_Budget__c stored = todaysBudget(agentId);
        Assert.areEqual(100, stored.API_Calls_Consumed__c);
        Assert.areEqual(50, stored.SOQL_Queries_Consumed__c);
        Assert.areEqual(30, stored.DML_Operations_Consumed__c);
    }

    @IsTest
    static void exhaustedBudgetIsDeniedAndOveragePersisted() {
        Id agentId = primaryAgent().Id;
        AgentGov_Budget__c budget = todaysBudget(agentId);
        budget.API_Calls_Consumed__c = 9999;
        update budget;

        Test.startTest();
        try {
            AgentGovBudgetManager.consumeBudget(agentId, AgentGovConstants.LIMIT_API_CALLS, 100);
            Assert.fail('Consumption past the allocation must be denied');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.BUDGET_EXCEEDED, e.getErrorCode());
            Assert.isTrue(
                e.getMessage().contains(AgentGovConstants.LIMIT_API_CALLS),
                'The message names the limit type'
            );
        }
        Test.stopTest();

        AgentGov_Budget__c stored = todaysBudget(agentId);
        Assert.areEqual(10099, stored.API_Calls_Consumed__c, 'The attempt that crossed the line is recorded');
        Assert.areEqual(AgentGovConstants.BUDGET_EXHAUSTED, stored.Budget_Status__c);
    }

    @IsTest
    static void blockThresholdDeniesBeforeExhaustion() {
        useDefaultThresholds();
        Id agentId = primaryAgent().Id;
        AgentGov_Budget__c budget = todaysBudget(agentId);
        budget.API_Calls_Consumed__c = 9400;
        update budget;

        Test.startTest();
        try {
            AgentGovBudgetManager.consumeBudget(agentId, AgentGovConstants.LIMIT_API_CALLS, 200);
            Assert.fail('Crossing the block threshold must be denied');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.BUDGET_EXCEEDED, e.getErrorCode());
        }
        Test.stopTest();

        AgentGov_Budget__c stored = todaysBudget(agentId);
        Assert.areEqual(AgentGovConstants.BUDGET_BLOCKED, stored.Budget_Status__c);
        Assert.areEqual(9600, stored.API_Calls_Consumed__c);
    }

    @IsTest
    static void warningThresholdKeepsRequestsAllowed() {
        useDefaultThresholds();
        Id agentId = primaryAgent().Id;

        Test.startTest();
        AgentGovBudgetManager.BudgetResult result = AgentGovBudgetManager.consumeBudget(
            agentId,
            AgentGovConstants.LIMIT_API_CALLS,
            8100
        );
        Test.stopTest();

        Assert.areEqual(AgentGovConstants.BUDGET_WARNING, result.budgetStatus);
        Assert.isTrue(result.allowed);
    }

    @IsTest
    static void mapOverloadDeniesLikeSingleOverload() {
        Id agentId = primaryAgent().Id;

        Test.startTest();
        try {
            AgentGovBudgetManager.consumeBudget(
                agentId,
                new Map<String, Integer>{ AgentGovConstants.LIMIT_DML_OPERATIONS => 3000 }
            );
            Assert.fail('The multi-limit overload must deny an exhausted budget');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.BUDGET_EXCEEDED, e.getErrorCode());
        }
        Test.stopTest();

        Assert.areEqual(AgentGovConstants.BUDGET_EXHAUSTED, todaysBudget(agentId).Budget_Status__c);
    }

    @IsTest
    static void statusReflectsWorstLimitType() {
        Id agentId = primaryAgent().Id;
        AgentGov_Budget__c budget = todaysBudget(agentId);
        budget.DML_Operations_Consumed__c = 3000;
        update budget;

        Test.startTest();
        try {
            AgentGovBudgetManager.consumeBudget(agentId, AgentGovConstants.LIMIT_SOQL_QUERIES, 1);
            Assert.fail('An agent whose DML budget is exhausted is denied every operation');
        } catch (AgentGovException e) {
            Assert.isTrue(e.getMessage().contains(AgentGovConstants.LIMIT_DML_OPERATIONS));
        }
        Test.stopTest();
    }

    @IsTest
    static void budgetIsCreatedOnFirstUseExactlyOnce() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'No Budget Agent',
            'Custom_Apex',
            true
        );

        Test.startTest();
        AgentGovBudgetManager.BudgetResult result = AgentGovBudgetManager.checkBudget(reg.Id);
        AgentGovBudgetManager.checkBudget(reg.Id);
        Test.stopTest();

        Assert.isTrue(result.allowed);
        Assert.areEqual(1, [SELECT COUNT() FROM AgentGov_Budget__c WHERE Agent_Registration__c = :reg.Id]);
        Assert.areEqual(
            AgentGovBudgetManager.buildBudgetKey(reg.Id, Date.today()),
            todaysBudget(reg.Id).Budget_Key__c,
            'The unique key is populated on creation'
        );
    }

    @IsTest
    static void createDailyBudgetIsIdempotent() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'Daily Budget Agent',
            'MCP_External',
            true
        );

        Test.startTest();
        AgentGov_Budget__c first = AgentGovBudgetManager.createDailyBudget(reg.Id);
        AgentGov_Budget__c second = AgentGovBudgetManager.createDailyBudget(reg.Id);
        Test.stopTest();

        Assert.areEqual(first.Id, second.Id, 'The second call returns the existing row');
        Assert.areEqual(1, [SELECT COUNT() FROM AgentGov_Budget__c WHERE Agent_Registration__c = :reg.Id]);
    }

    @IsTest
    static void duplicateBudgetRowIsRejectedByUniqueKey() {
        Id agentId = primaryAgent().Id;
        try {
            AgentGovTestDataFactory.createBudget(agentId, true);
            Assert.fail('A second budget for the same agent and day must be rejected');
        } catch (DmlException e) {
            Assert.areEqual(StatusCode.DUPLICATE_VALUE, e.getDmlType(0));
        }
    }

    @IsTest
    static void creditRestoresLowerStatus() {
        useDefaultThresholds();
        Id agentId = primaryAgent().Id;
        AgentGov_Budget__c budget = todaysBudget(agentId);
        budget.API_Calls_Consumed__c = 9600;
        budget.Budget_Status__c = AgentGovConstants.BUDGET_BLOCKED;
        update budget;

        Test.startTest();
        AgentGovBudgetManager.BudgetResult result = AgentGovBudgetManager.creditBudget(
            agentId,
            AgentGovConstants.LIMIT_API_CALLS,
            2000
        );
        Test.stopTest();

        Assert.areEqual(
            AgentGovConstants.BUDGET_NORMAL,
            result.budgetStatus,
            'Status is re-evaluated from the corrected usage'
        );
        Assert.areEqual(7600, todaysBudget(agentId).API_Calls_Consumed__c);
    }

    @IsTest
    static void nullConsumedCountersAreTreatedAsZero() {
        Id agentId = primaryAgent().Id;
        AgentGov_Budget__c budget = todaysBudget(agentId);
        budget.API_Calls_Consumed__c = null;
        update budget;

        Test.startTest();
        AgentGovBudgetManager.BudgetResult result = AgentGovBudgetManager.consumeBudget(
            agentId,
            AgentGovConstants.LIMIT_API_CALLS,
            5
        );
        Test.stopTest();

        Assert.areEqual(9995, result.apiCallsRemaining);
    }

    @IsTest
    static void bulkConsumptionReportsPerAgent() {
        List<AgentGov_Registration__c> agents = AgentGovTestDataFactory.createRegistrations(2, 'Flow_Based');
        Map<Id, Map<String, Integer>> consumption = new Map<Id, Map<String, Integer>>{
            agents[0].Id => new Map<String, Integer>{ AgentGovConstants.LIMIT_DML_OPERATIONS => 5000 },
            agents[1].Id => new Map<String, Integer>{ AgentGovConstants.LIMIT_DML_OPERATIONS => 5 }
        };

        Test.startTest();
        AgentGovBudgetManager.BatchOutcome outcome = AgentGovBudgetManager.consumeBudgets(consumption);
        Test.stopTest();

        Assert.isTrue(outcome.failures.containsKey(agents[0].Id), 'The over-budget agent is reported as a failure');
        Assert.isTrue(outcome.results.containsKey(agents[1].Id), 'The other agent is charged normally');
        Assert.areEqual(2995, outcome.results.get(agents[1].Id).dmlOperationsRemaining);
        Assert.areEqual(
            5000,
            todaysBudget(agents[0].Id).DML_Operations_Consumed__c,
            'Overage is persisted for the denied agent'
        );
    }

    @IsTest
    static void bulkConsumptionFlagsUnknownAgentsAndInvalidLimitTypes() {
        Id unknownId = AgentGov_Registration__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';
        Map<Id, Map<String, Integer>> consumption = new Map<Id, Map<String, Integer>>{
            unknownId => new Map<String, Integer>{ AgentGovConstants.LIMIT_API_CALLS => 1 },
            primaryAgent().Id => new Map<String, Integer>{ 'Bogus' => 1 }
        };

        AgentGovBudgetManager.BatchOutcome outcome = AgentGovBudgetManager.consumeBudgets(consumption);

        Assert.areEqual(2, outcome.failures.size());
        Assert.areEqual(AgentGovException.ErrorCode.AGENT_NOT_FOUND, outcome.failures.get(unknownId).getErrorCode());
        Assert.areEqual(
            AgentGovException.ErrorCode.INVALID_INPUT,
            outcome.failures.get(primaryAgent().Id).getErrorCode()
        );
    }

    @IsTest
    static void invalidLimitTypeIsRejected() {
        try {
            AgentGovBudgetManager.consumeBudget(primaryAgent().Id, 'Bogus', 1);
            Assert.fail('An unknown limit type must be rejected');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
        }
    }

    @IsTest
    static void sessionCountersFollowConsumption() {
        Id agentId = primaryAgent().Id;
        AgentGov_Session__c session = AgentGovTestDataFactory.createSession(agentId, true);

        Test.startTest();
        AgentGovBudgetManager.consumeBudget(
            agentId,
            new Map<String, Integer>{
                AgentGovConstants.LIMIT_API_CALLS => 3,
                AgentGovConstants.LIMIT_DML_OPERATIONS => 2
            }
        );
        Test.stopTest();

        AgentGov_Session__c updated = [
            SELECT API_Calls_Used__c, DML_Statements_Used__c, Actions_Count__c
            FROM AgentGov_Session__c
            WHERE Id = :session.Id
        ];
        Assert.areEqual(3, updated.API_Calls_Used__c);
        Assert.areEqual(2, updated.DML_Statements_Used__c);
        Assert.areEqual(1, updated.Actions_Count__c);
    }

    @IsTest
    static void resetCreatesRowsOnceForActiveAgents() {
        AgentGovTestDataFactory.createRegistration('Second Active Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovBudgetManager.resetDailyBudgets();
        AgentGovBudgetManager.resetDailyBudgets();
        Test.stopTest();

        Assert.areEqual(
            2,
            [SELECT COUNT() FROM AgentGov_Budget__c WHERE Budget_Date__c = TODAY],
            'One row per active agent, no duplicates'
        );
    }

    @IsTest
    static void resolveStatusFollowsThresholdLadder() {
        AgentGovBudgetManager.Thresholds thresholds = new AgentGovBudgetManager.Thresholds();
        thresholds.warning = 80;
        thresholds.throttle = 90;
        thresholds.block = 95;

        Assert.areEqual(AgentGovConstants.BUDGET_NORMAL, AgentGovBudgetManager.resolveStatus(79.9, thresholds));
        Assert.areEqual(AgentGovConstants.BUDGET_WARNING, AgentGovBudgetManager.resolveStatus(80, thresholds));
        Assert.areEqual(AgentGovConstants.BUDGET_THROTTLED, AgentGovBudgetManager.resolveStatus(90, thresholds));
        Assert.areEqual(AgentGovConstants.BUDGET_BLOCKED, AgentGovBudgetManager.resolveStatus(95, thresholds));
        Assert.areEqual(AgentGovConstants.BUDGET_EXHAUSTED, AgentGovBudgetManager.resolveStatus(100, thresholds));
    }

    @IsTest
    static void getRemainingBudgetAliasesCheckBudget() {
        AgentGovBudgetManager.BudgetResult result = AgentGovBudgetManager.getRemainingBudget(primaryAgent().Id);
        Assert.areEqual(5000, result.soqlQueriesRemaining);
    }
}
