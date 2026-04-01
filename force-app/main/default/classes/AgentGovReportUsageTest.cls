@IsTest
private class AgentGovReportUsageTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    @IsTest
    static void testReportUsage() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Report Usage Agent', AgentGovConstants.AGENT_TYPE_CUSTOM_APEX, true);
        reg.Status__c = AgentGovConstants.STATUS_ACTIVE;
        update reg;

        AgentGovReportUsage.Request req = new AgentGovReportUsage.Request();
        req.registrationId = reg.Id;
        req.apiCallsUsed = 5;
        req.soqlQueriesUsed = 3;
        req.dmlStatementsUsed = 2;

        Test.startTest();
        List<AgentGovReportUsage.Result> results = AgentGovReportUsage.reportUsage(new List<AgentGovReportUsage.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return 1 result');
        System.assertNotEquals(null, results[0].budgetStatus, 'Should have budget status');

        // Verify budget was consumed by actual amounts
        AgentGov_Budget__c budget = [SELECT API_Calls_Consumed__c, SOQL_Queries_Consumed__c, DML_Operations_Consumed__c
            FROM AgentGov_Budget__c WHERE Agent_Registration__c = :reg.Id AND Budget_Date__c = TODAY];
        System.assertEquals(5, budget.API_Calls_Consumed__c, 'API calls should show 5');
        System.assertEquals(3, budget.SOQL_Queries_Consumed__c, 'SOQL queries should show 3');
        System.assertEquals(2, budget.DML_Operations_Consumed__c, 'DML operations should show 2');
    }

    @IsTest
    static void testReportUsageNoConsumption() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('No Usage Agent', AgentGovConstants.AGENT_TYPE_CUSTOM_APEX, true);
        reg.Status__c = AgentGovConstants.STATUS_ACTIVE;
        update reg;

        AgentGovReportUsage.Request req = new AgentGovReportUsage.Request();
        req.registrationId = reg.Id;

        Test.startTest();
        List<AgentGovReportUsage.Result> results = AgentGovReportUsage.reportUsage(new List<AgentGovReportUsage.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return 1 result');
        System.assertEquals(AgentGovConstants.BUDGET_NORMAL, results[0].budgetStatus, 'Should be Normal');
    }
}
