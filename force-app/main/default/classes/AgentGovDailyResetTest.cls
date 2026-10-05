/**
 * @description Tests for the scheduled daily budget reset.
 */
@IsTest
private class AgentGovDailyResetTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGovTestDataFactory.createRegistration('Reset Agent', 'Agentforce', true);
    }

    @IsTest
    static void createsTodaysBudgetOnceForActiveAgents() {
        Test.startTest();
        new AgentGovDailyReset().execute(null);
        new AgentGovDailyReset().execute(null);
        Test.stopTest();

        Date orgToday = AgentGovBudgetManager.budgetDate();
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM AgentGov_Budget__c WHERE Budget_Date__c = :orgToday],
            'Running twice does not duplicate rows'
        );
    }

    @IsTest
    static void jobCanBeScheduled() {
        Test.startTest();
        Id jobId = System.schedule('AgentGov Daily Reset Test', '0 0 0 * * ?', new AgentGovDailyReset());
        Test.stopTest();

        Assert.areEqual(
            '0 0 0 * * ?',
            [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId].CronExpression,
            'The documented System.schedule call schedules the midnight run'
        );
    }
}
