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
        return [
            SELECT SOQL_Queries_Consumed__c, DML_Operations_Consumed__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c = :registrationId AND Budget_Date__c = TODAY
        ];
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
