@IsTest
private class AgentGovDailyResetTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGovTestDataFactory.createRegistration('Reset Agent', 'Agentforce', true);
    }

    @IsTest
    static void testExecute() {
        Test.startTest();
        AgentGovDailyReset job = new AgentGovDailyReset();
        job.execute(null);
        Test.stopTest();

        List<AgentGov_Budget__c> budgets = [SELECT Id FROM AgentGov_Budget__c WHERE Budget_Date__c = :Date.today()];
        System.assert(budgets.size() >= 1, 'Should create budget records');
    }
}
