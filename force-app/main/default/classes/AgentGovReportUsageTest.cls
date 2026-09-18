/**
 * @description Tests for the Report Agent Usage invocable.
 */
@IsTest
private class AgentGovReportUsageTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    private static AgentGovReportUsage.Request request(Id registrationId, Integer api, Integer soql, Integer dml) {
        AgentGovReportUsage.Request req = new AgentGovReportUsage.Request();
        req.registrationId = registrationId;
        req.apiCallsUsed = api;
        req.soqlQueriesUsed = soql;
        req.dmlStatementsUsed = dml;
        return req;
    }

    @IsTest
    static void reportedUsageIsChargedAndSummedPerAgent() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'Report Usage Agent',
            AgentGovConstants.AGENT_TYPE_CUSTOM_APEX,
            true
        );

        Test.startTest();
        List<AgentGovReportUsage.Result> results = AgentGovReportUsage.reportUsage(
            new List<AgentGovReportUsage.Request>{ request(reg.Id, 5, 3, 2), request(reg.Id, 1, 0, 0) }
        );
        Test.stopTest();

        Assert.areEqual(2, results.size());
        Assert.isTrue(results[0].allowed);
        Assert.areEqual(AgentGovConstants.BUDGET_NORMAL, results[0].budgetStatus);
        AgentGov_Budget__c budget = [
            SELECT API_Calls_Consumed__c, SOQL_Queries_Consumed__c, DML_Operations_Consumed__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c = :reg.Id
        ];
        Assert.areEqual(6, budget.API_Calls_Consumed__c);
        Assert.areEqual(3, budget.SOQL_Queries_Consumed__c);
        Assert.areEqual(2, budget.DML_Operations_Consumed__c);
    }

    @IsTest
    static void noUsageReturnsCurrentStatus() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'No Usage Agent',
            AgentGovConstants.AGENT_TYPE_CUSTOM_APEX,
            true
        );

        List<AgentGovReportUsage.Result> results = AgentGovReportUsage.reportUsage(
            new List<AgentGovReportUsage.Request>{ request(reg.Id, null, null, null) }
        );

        Assert.areEqual(AgentGovConstants.BUDGET_NORMAL, results[0].budgetStatus);
        Assert.isTrue(results[0].allowed);
    }

    @IsTest
    static void overBudgetReportIsFlagged() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'Heavy Agent',
            AgentGovConstants.AGENT_TYPE_CUSTOM_APEX,
            true
        );
        Id unknownId = AgentGov_Registration__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';

        List<AgentGovReportUsage.Result> results = AgentGovReportUsage.reportUsage(
            new List<AgentGovReportUsage.Request>{ request(reg.Id, 0, 0, 3000), request(unknownId, 1, 0, 0) }
        );

        Assert.isFalse(results[0].allowed);
        Assert.areEqual(
            AgentGovConstants.BUDGET_EXHAUSTED,
            results[0].budgetStatus,
            'The status after the report is still returned'
        );
        Assert.isTrue(results[0].errorMessage.contains(AgentGovConstants.LIMIT_DML_OPERATIONS));
        Assert.isFalse(results[1].allowed);
        Assert.areEqual(AgentGovConstants.ERR_AGENT_NOT_FOUND, results[1].errorMessage);
    }

    @IsTest
    static void nothingIsChargedWhileGovernanceIsDisabled() {
        // This class creates its agents per test, so build one here rather than querying.
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'Bypass Usage Agent',
            AgentGovConstants.AGENT_TYPE_CUSTOM_APEX,
            true
        );
        AgentGovTestDataFactory.createBudget(reg.Id, true);
        AgentGov_Budget__c budget = [SELECT Id FROM AgentGov_Budget__c WHERE Agent_Registration__c = :reg.Id];
        budget.API_Calls_Consumed__c = 7;
        update budget;

        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();

        AgentGovReportUsage.Request req = new AgentGovReportUsage.Request();
        req.registrationId = reg.Id;
        req.apiCallsUsed = 900;

        Test.startTest();
        AgentGovReportUsage.reportUsage(new List<AgentGovReportUsage.Request>{ req });
        Test.stopTest();

        Assert.areEqual(
            7,
            [
                SELECT API_Calls_Consumed__c
                FROM AgentGov_Budget__c
                WHERE Agent_Registration__c = :reg.Id
            ]
            .API_Calls_Consumed__c,
            'The emergency bypass suspends reporting charges too'
        );
    }
}
