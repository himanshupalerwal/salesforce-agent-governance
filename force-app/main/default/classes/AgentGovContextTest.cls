/**
 * @description Tests for AgentGovContext: measurement, nesting, and exception propagation.
 */
@IsTest
private class AgentGovContextTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    private static AgentGov_Registration__c activeAgent(String name) {
        return AgentGovTestDataFactory.createRegistration(name, AgentGovConstants.AGENT_TYPE_CUSTOM_APEX, true);
    }

    private static AgentGov_Budget__c budgetOf(Id registrationId) {
        Date orgToday = AgentGovBudgetManager.budgetDate();
        return [
            SELECT SOQL_Queries_Consumed__c, DML_Operations_Consumed__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c = :registrationId AND Budget_Date__c = :orgToday
        ];
    }

    @IsTest
    static void eachUnitOfWorkIsAuditedWithItsOwnDuration() {
        AgentGov_Registration__c agent = activeAgent('Audited Unit');

        Test.startTest();
        AgentGovContext.startTracking(agent.Id);
        List<Account> accounts = [SELECT Id FROM Account LIMIT 1];
        AgentGovContext.stopTracking();
        Test.getEventBus().deliver();
        Test.stopTest();

        AgentGov_Action_Log__c row = [
            SELECT Action_Type__c, Status__c, Details__c, Execution_Time_Ms__c
            FROM AgentGov_Action_Log__c
            WHERE Agent_Registration__c = :agent.Id
        ];
        Assert.areEqual(AgentGovConstants.ACTION_APEX, row.Action_Type__c);
        Assert.areEqual(AgentGovConstants.ACTION_SUCCESS, row.Status__c);
        Assert.isTrue(row.Details__c.contains(AgentGovConstants.LIMIT_SOQL_QUERIES), row.Details__c);
        Assert.isNotNull(row.Execution_Time_Ms__c, 'The unit records how long it ran');
        Assert.isNotNull(accounts);
    }

    @IsTest
    static void measuresQueriesBetweenStartAndStop() {
        AgentGov_Registration__c reg = activeAgent('Context Test Agent');

        Test.startTest();
        AgentGovContext context = AgentGovContext.startTracking(reg.Id);
        Assert.areEqual(reg.Id, AgentGovContext.getCurrentContext().getRegistrationId());
        List<AgentGov_Registration__c> ignored = [SELECT Id FROM AgentGov_Registration__c LIMIT 5];
        AgentGovBudgetManager.BudgetResult result = AgentGovContext.stopTracking();
        Test.stopTest();

        Assert.isNotNull(context);
        Assert.isNull(AgentGovContext.getCurrentContext(), 'The context is cleared after stop');
        Assert.areEqual(4999, result.soqlQueriesRemaining, 'Exactly the one query inside the context is charged');
    }

    @IsTest
    static void stopWithoutStartIsRejected() {
        AgentGovContext.resetForTest();
        try {
            AgentGovContext.stopTracking();
            Assert.fail('Stopping without a context must be rejected');
        } catch (AgentGovException e) {
            Assert.isTrue(e.getMessage().contains('No active'));
        }
    }

    @IsTest
    static void trackingIsRefusedForADeactivatedAgent() {
        AgentGov_Registration__c reg = activeAgent('Deactivated Apex Agent');
        AgentGovRegistryService.deactivateAgent(reg.Id);
        AgentGovSelector.clearCache();

        try {
            AgentGovContext.startTracking(reg.Id);
            Assert.fail('A deactivated agent must not start a unit of work');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.AGENT_NOT_ACTIVE, e.getErrorCode());
        }
    }

    @IsTest
    static void startTrackingRejectsNullId() {
        try {
            AgentGovContext.startTracking(null);
            Assert.fail('A null Id must be rejected');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.INVALID_INPUT, e.getErrorCode());
        }
    }

    @IsTest
    static void sessionIsCarriedOnContext() {
        AgentGov_Registration__c reg = activeAgent('Session Context Agent');
        AgentGov_Session__c session = AgentGovTestDataFactory.createSession(reg.Id, true);

        AgentGovContext context = AgentGovContext.startTracking(reg.Id, session.Id);
        AgentGovContext.stopTracking();

        Assert.areEqual(session.Id, context.getSessionId());
    }

    @IsTest
    static void executeGovernedChargesMeasuredUsage() {
        AgentGov_Registration__c reg = activeAgent('Governed Test Agent');

        Test.startTest();
        AgentGovBudgetManager.BudgetResult result = AgentGovContext.executeGoverned(reg.Id, new QueryingAction());
        Test.stopTest();

        Assert.areEqual(4999, result.soqlQueriesRemaining);
        Assert.isNull(AgentGovContext.getCurrentContext());
    }

    @IsTest
    static void executeGovernedPropagatesActionFailureAfterCharging() {
        AgentGov_Registration__c reg = activeAgent('Failing Agent');

        Test.startTest();
        try {
            AgentGovContext.executeGoverned(reg.Id, new FailingAction());
            Assert.fail('The action\'s exception must propagate');
        } catch (IllegalArgumentException e) {
            Assert.areEqual('action failed', e.getMessage());
        }
        Test.stopTest();

        Assert.isNull(AgentGovContext.getCurrentContext(), 'The context is cleared even when the action throws');
        Assert.areEqual(1, budgetOf(reg.Id).SOQL_Queries_Consumed__c, 'Usage before the failure is still charged');
    }

    // One SOQL query is a whole day's allocation, so any measured query takes the agent over.
    private static AgentGov_Registration__c agentWithOneQueryLeft(String name) {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            name,
            AgentGovConstants.AGENT_TYPE_CUSTOM_APEX,
            false
        );
        reg.Daily_SOQL_Budget__c = 1;
        insert reg;
        return reg;
    }

    private static AgentGov_Action_Log__c apexRowOf(Id registrationId) {
        return [
            SELECT Status__c, Error_Message__c
            FROM AgentGov_Action_Log__c
            WHERE Agent_Registration__c = :registrationId AND Action_Type__c = :AgentGovConstants.ACTION_APEX
        ];
    }

    @IsTest
    static void aFailedActionThatAlsoCrossesTheBudgetKeepsItsOwnError() {
        AgentGov_Registration__c reg = agentWithOneQueryLeft('Failing Over Budget');

        Test.startTest();
        try {
            AgentGovContext.executeGoverned(reg.Id, new FailingAction());
            Assert.fail('The action\'s exception must propagate');
        } catch (IllegalArgumentException e) {
            Assert.areEqual('action failed', e.getMessage(), 'The action\'s own exception, not the budget denial');
        }
        Test.getEventBus().deliver();
        Test.stopTest();

        AgentGov_Action_Log__c row = apexRowOf(reg.Id);
        Assert.areEqual(AgentGovConstants.ACTION_FAILURE, row.Status__c, 'The unit failed; it was not refused');
        Assert.isTrue(
            row.Error_Message__c.contains('action failed'),
            'The action\'s error is kept: ' + row.Error_Message__c
        );
        Assert.isTrue(
            row.Error_Message__c.contains(AgentGovConstants.ERR_BUDGET_EXCEEDED),
            'The budget it crossed is noted: ' + row.Error_Message__c
        );
        Assert.areEqual(1, budgetOf(reg.Id).SOQL_Queries_Consumed__c, 'The usage was charged');
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM AgentGov_Action_Log__c WHERE Action_Type__c = :AgentGovConstants.ACTION_SYSTEM],
            'A charge that crossed the budget is not a bookkeeping failure'
        );
    }

    @IsTest
    static void aSucceededUnitThatCrossesTheBudgetIsDenied() {
        AgentGov_Registration__c reg = agentWithOneQueryLeft('Succeeding Over Budget');

        Test.startTest();
        try {
            AgentGovContext.executeGoverned(reg.Id, new QueryingAction());
            Assert.fail('Crossing the budget must be refused');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.BUDGET_EXCEEDED, e.getErrorCode());
        }
        Test.getEventBus().deliver();
        Test.stopTest();

        AgentGov_Action_Log__c row = apexRowOf(reg.Id);
        Assert.areEqual(AgentGovConstants.ACTION_DENIED, row.Status__c);
        Assert.isTrue(row.Error_Message__c.startsWith(AgentGovConstants.ERR_BUDGET_EXCEEDED), row.Error_Message__c);
    }

    @IsTest
    static void aFailedActionWhoseUsageCannotBeChargedIsRecordedAsABookkeepingFailure() {
        // No registration exists for this Id, so the charge itself fails.
        Id unknownId = AgentGov_Registration__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';

        Test.startTest();
        try {
            AgentGovContext.executeGoverned(unknownId, new FailingAction());
            Assert.fail('The action\'s exception must propagate');
        } catch (IllegalArgumentException e) {
            Assert.areEqual('action failed', e.getMessage(), 'The bookkeeping failure does not replace it');
        }
        Test.getEventBus().deliver();
        Test.stopTest();

        List<AgentGov_Action_Log__c> notes = new List<AgentGov_Action_Log__c>();
        for (AgentGov_Action_Log__c row : [
            SELECT Agent_Registration__c, Status__c, Details__c
            FROM AgentGov_Action_Log__c
            WHERE Action_Type__c = :AgentGovConstants.ACTION_SYSTEM
        ]) {
            if (row.Details__c != null && row.Details__c.startsWith('A failed governed action')) {
                notes.add(row);
            }
        }
        Assert.areEqual(1, notes.size(), 'The failed charge is recorded once');
        Assert.areEqual(AgentGovConstants.ACTION_FAILURE, notes[0].Status__c);
        Assert.isTrue(notes[0].Details__c.contains(AgentGovConstants.ERR_AGENT_NOT_FOUND), notes[0].Details__c);
        Assert.isNull(notes[0].Agent_Registration__c, 'An agent that does not exist cannot be linked');
    }

    @IsTest
    static void nestedContextsChargeEachAgentSeparately() {
        AgentGov_Registration__c parentAgent = activeAgent('Outer Agent');
        AgentGov_Registration__c childAgent = activeAgent('Inner Agent');

        Test.startTest();
        AgentGovContext.startTracking(parentAgent.Id);
        List<AgentGov_Registration__c> outerQuery = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        AgentGovContext.startTracking(childAgent.Id);
        List<AgentGov_Registration__c> innerQuery = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        AgentGovBudgetManager.BudgetResult innerResult = AgentGovContext.stopTracking();
        AgentGovBudgetManager.BudgetResult outerResult = AgentGovContext.stopTracking();
        Test.stopTest();

        Assert.areEqual(4999, innerResult.soqlQueriesRemaining, 'The inner agent pays for its own query');
        Assert.areEqual(
            1,
            budgetOf(parentAgent.Id).SOQL_Queries_Consumed__c,
            'The outer agent pays for its query but not for the inner agent\'s work'
        );
        Assert.isNotNull(outerResult);
    }

    private class QueryingAction implements AgentGovContext.AgentGovAction {
        public void execute() {
            List<AgentGov_Registration__c> ignored = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
        }
    }

    private class FailingAction implements AgentGovContext.AgentGovAction {
        public void execute() {
            List<AgentGov_Registration__c> ignored = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];
            throw new IllegalArgumentException('action failed');
        }
    }
}
