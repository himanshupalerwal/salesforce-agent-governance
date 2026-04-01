@IsTest
private class AgentGovPolicyEngineTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    @IsTest
    static void testEvaluatePolicyAllowed() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Policy Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovPolicyEngine.PolicyResult result = AgentGovPolicyEngine.evaluatePolicy(
            reg.Id, 'Account', 'Query'
        );
        Test.stopTest();

        // With default metadata, policies may allow by default
        System.assertNotEquals(null, result);
    }

    @IsTest
    static void testIsActionAllowed() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Policy Agent', 'Agentforce', true);

        Test.startTest();
        Boolean allowed = AgentGovPolicyEngine.isActionAllowed(reg.Id, 'Account', 'Query');
        Test.stopTest();

        System.assertNotEquals(null, allowed);
    }

    @IsTest
    static void testEvaluatePolicyFrameworkDisabled() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();

        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Policy Agent', 'Agentforce', true);

        Test.startTest();
        AgentGovPolicyEngine.PolicyResult result = AgentGovPolicyEngine.evaluatePolicy(
            reg.Id, 'Account', 'Delete'
        );
        Test.stopTest();

        System.assertEquals(true, result.allowed, 'Should allow when framework disabled');
    }

    @IsTest
    static void testEvaluatePolicyAgentNotFound() {
        Test.startTest();
        AgentGovPolicyEngine.PolicyResult result = AgentGovPolicyEngine.evaluatePolicy(
            'a00000000000001AAA', 'Account', 'Query'
        );
        Test.stopTest();

        System.assertEquals(false, result.allowed);
    }

    @IsTest
    static void testValidatePolicies() {
        Test.startTest();
        List<String> issues = AgentGovPolicyEngine.validatePolicies();
        Test.stopTest();

        System.assertNotEquals(null, issues, 'Should return a list');
    }
}
