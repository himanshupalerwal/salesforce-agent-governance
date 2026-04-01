/**
 * @description Evaluates agent policies before actions are executed.
 *              Enforces object-level, field-level, and operation-level access controls
 *              based on Custom Metadata Type configurations.
 * @author Himanshu Palerwal
 */
public with sharing class AgentGovPolicyEngine {

    /**
     * @description Result of a policy evaluation.
     */
    public class PolicyResult {
        @AuraEnabled public Boolean allowed;
        @AuraEnabled public String denialReason;
        @AuraEnabled public Integer maxRecords;
        @AuraEnabled public List<String> restrictedFields;
    }

    /**
     * @description Evaluates whether an agent is allowed to perform an action.
     * @param registrationId The agent registration ID
     * @param objectName The Salesforce object API name
     * @param operation The operation type (use AgentGovConstants.ACTION_*)
     * @return PolicyResult with evaluation details
     */
    public static PolicyResult evaluatePolicy(Id registrationId, String objectName, String operation) {
        PolicyResult result = new PolicyResult();
        result.allowed = true;
        result.restrictedFields = new List<String>();

        // If framework is disabled, allow everything
        if (!AgentGovSelector.isFrameworkEnabled()) {
            return result;
        }

        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById(registrationId);
        if (reg == null) {
            result.allowed = false;
            result.denialReason = AgentGovConstants.ERR_AGENT_NOT_FOUND;
            return result;
        }

        // Get applicable policies
        List<AgentGov_Policy__mdt> policies = AgentGovSelector.getPoliciesForAgentType(reg.Agent_Type__c);

        if (policies.isEmpty()) {
            // No policies defined — default allow
            return result;
        }

        Boolean hasExplicitDeny = false;
        Boolean hasExplicitAllow = false;

        for (AgentGov_Policy__mdt policy : policies) {
            // Skip invalid policies gracefully
            if (String.isBlank(policy.Object_Name__c) || String.isBlank(policy.Operation__c)) {
                System.debug(LoggingLevel.WARN, 'AgentGov: Skipping invalid policy: ' + policy.DeveloperName);
                continue;
            }

            // Check if policy matches this object
            Boolean objectMatch = policy.Object_Name__c == AgentGovConstants.POLICY_WILDCARD
                || policy.Object_Name__c.equalsIgnoreCase(objectName);

            // Check if policy matches this operation
            Boolean operationMatch = policy.Operation__c == AgentGovConstants.POLICY_WILDCARD
                || policy.Operation__c.equalsIgnoreCase(operation);

            if (objectMatch && operationMatch) {
                if (policy.Is_Allowed__c == false) {
                    hasExplicitDeny = true;
                    result.allowed = false;
                    result.denialReason = String.format(
                        AgentGovConstants.ERR_POLICY_VIOLATION,
                        new List<String>{ reg.Agent_Name__c, operation, objectName }
                    );
                } else {
                    hasExplicitAllow = true;

                    // Collect field restrictions
                    if (String.isNotBlank(policy.Field_Restrictions__c)) {
                        for (String field : policy.Field_Restrictions__c.split(',')) {
                            result.restrictedFields.add(field.trim());
                        }
                    }

                    // Set max records
                    if (policy.Max_Records_Per_Transaction__c != null) {
                        if (result.maxRecords == null || policy.Max_Records_Per_Transaction__c < result.maxRecords) {
                            result.maxRecords = (Integer) policy.Max_Records_Per_Transaction__c;
                        }
                    }
                }
            }
        }

        // Explicit deny overrides allow
        if (hasExplicitDeny) {
            result.allowed = false;
        }

        return result;
    }

    /**
     * @description Convenience method to check if an action is allowed (boolean only).
     * @param registrationId The agent registration ID
     * @param objectName The Salesforce object API name
     * @param operation The operation type
     * @return True if the action is allowed
     */
    public static Boolean isActionAllowed(Id registrationId, String objectName, String operation) {
        return evaluatePolicy(registrationId, objectName, operation).allowed;
    }

    /**
     * @description Validates all policy metadata records and returns any issues found.
     * @return List of validation error messages (empty if all valid)
     */
    public static List<String> validatePolicies() {
        List<String> issues = new List<String>();
        List<AgentGov_Policy__mdt> policies = AgentGovSelector.getPolicies();

        for (AgentGov_Policy__mdt policy : policies) {
            if (String.isBlank(policy.Object_Name__c)) {
                issues.add('Policy ' + policy.DeveloperName + ': Object_Name__c is blank.');
            }
            if (String.isBlank(policy.Operation__c)) {
                issues.add('Policy ' + policy.DeveloperName + ': Operation__c is blank.');
            }
            if (String.isNotBlank(policy.Operation__c)
                && policy.Operation__c != AgentGovConstants.POLICY_WILDCARD
                && !AgentGovConstants.VALID_OPERATIONS.contains(policy.Operation__c)) {
                issues.add('Policy ' + policy.DeveloperName + ': Invalid operation "' + policy.Operation__c + '".');
            }
        }
        return issues;
    }
}
