/**
 * @description Tests for AgentGovPolicyEngine against the shipped policy records and the
 *              field and record-count assertions.
 */
@IsTest
private class AgentGovPolicyEngineTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    private static AgentGovPolicyEngine.PolicyResult policyWith(List<String> restrictedFields, Integer maxRecords) {
        AgentGovPolicyEngine.PolicyResult policy = new AgentGovPolicyEngine.PolicyResult();
        policy.allowed = true;
        policy.restrictedFields = restrictedFields;
        policy.maxRecords = maxRecords;
        return policy;
    }

    @IsTest
    static void shippedPolicyDeniesMcpAccountDelete() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'MCP Agent',
            AgentGovConstants.AGENT_TYPE_MCP_EXTERNAL,
            true
        );

        AgentGovPolicyEngine.PolicyResult result = AgentGovPolicyEngine.evaluatePolicy(
            reg.Id,
            'Account',
            AgentGovConstants.ACTION_DELETE
        );

        Assert.isFalse(result.allowed, 'The shipped policy denies deleting Accounts');
        Assert.isTrue(result.denialReason.contains('MCP Agent'));
        Assert.isFalse(
            AgentGovPolicyEngine.isActionAllowed(reg.Id, 'account', 'delete'),
            'Matching is case-insensitive'
        );
    }

    @IsTest
    static void shippedPolicyAllowsMcpAccountQueryWithRecordCap() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'MCP Agent',
            AgentGovConstants.AGENT_TYPE_MCP_EXTERNAL,
            true
        );

        AgentGovPolicyEngine.PolicyResult result = AgentGovPolicyEngine.evaluatePolicy(
            reg.Id,
            'Account',
            AgentGovConstants.ACTION_QUERY
        );

        Assert.isTrue(result.allowed);
        Assert.areEqual(200, result.maxRecords, 'The shipped read policy applies to Query operations');
    }

    @IsTest
    static void unmatchedOperationsDefaultToAllow() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'Policy Agent',
            AgentGovConstants.AGENT_TYPE_AGENTFORCE,
            true
        );

        Assert.isTrue(AgentGovPolicyEngine.evaluatePolicy(reg.Id, 'Account', AgentGovConstants.ACTION_UPDATE).allowed);
    }

    @IsTest
    static void aBlankObjectOrOperationIsDeniedRatherThanMatchingNothing() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'Policy Agent',
            AgentGovConstants.AGENT_TYPE_AGENTFORCE,
            true
        );

        // A policy names the object it governs, so a blank object name matches no policy and
        // would skip every object-scoped rule. Treating that as a pass turned an omitted field
        // into a way to be authorized for an operation a deny policy forbids.
        Assert.isFalse(
            AgentGovPolicyEngine.evaluatePolicy(reg.Id, null, AgentGovConstants.ACTION_DELETE).allowed,
            'A blank object name is denied, not silently allowed'
        );
        Assert.isFalse(
            AgentGovPolicyEngine.evaluatePolicy(reg.Id, 'Account', null).allowed,
            'A blank operation is denied, not silently allowed'
        );
        Assert.isFalse(AgentGovPolicyEngine.evaluatePolicy(reg.Id, null, null).allowed);
    }

    @IsTest
    static void disabledFrameworkAllowsEverything() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'MCP Agent',
            AgentGovConstants.AGENT_TYPE_MCP_EXTERNAL,
            true
        );

        Assert.isTrue(AgentGovPolicyEngine.evaluatePolicy(reg.Id, 'Account', AgentGovConstants.ACTION_DELETE).allowed);
    }

    @IsTest
    static void unknownAgentIsDenied() {
        Id unknownId = AgentGov_Registration__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';
        AgentGovPolicyEngine.PolicyResult result = AgentGovPolicyEngine.evaluatePolicy(
            unknownId,
            'Account',
            AgentGovConstants.ACTION_QUERY
        );
        Assert.isFalse(result.allowed);
        Assert.areEqual(AgentGovConstants.ERR_AGENT_NOT_FOUND, result.denialReason);
    }

    @IsTest
    static void restrictedFieldsAreDeniedCaseInsensitively() {
        AgentGovPolicyEngine.PolicyResult policy = policyWith(new List<String>{ 'AnnualRevenue', 'Phone' }, null);

        AgentGovPolicyEngine.assertFieldsAllowed(policy, new Set<String>{ 'Name', 'Industry' });
        try {
            AgentGovPolicyEngine.assertFieldsAllowed(policy, new Set<String>{ 'Name', 'annualrevenue' });
            Assert.fail('A restricted field must be denied');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.POLICY_VIOLATION, e.getErrorCode());
            Assert.isTrue(e.getMessage().contains('annualrevenue'));
        }
    }

    @IsTest
    static void recordCountCapIsEnforced() {
        AgentGovPolicyEngine.PolicyResult policy = policyWith(new List<String>(), 10);

        AgentGovPolicyEngine.assertRecordCount(policy, 10);
        AgentGovPolicyEngine.assertRecordCount(policyWith(new List<String>(), null), 5000);
        try {
            AgentGovPolicyEngine.assertRecordCount(policy, 11);
            Assert.fail('Exceeding the cap must be denied');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.POLICY_VIOLATION, e.getErrorCode());
            Assert.isTrue(e.getMessage().contains('10') && e.getMessage().contains('11'));
        }
    }

    @IsTest
    static void shippedPoliciesAreValid() {
        Assert.isTrue(AgentGovPolicyEngine.validatePolicies().isEmpty(), 'Shipped policy records use valid operations');
    }
}
