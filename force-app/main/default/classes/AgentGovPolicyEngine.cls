/**
 * @description Evaluates the metadata-driven access policies before an agent acts.
 *
 *              Policies live in AgentGov_Policy__mdt and match on agent type, object, and
 *              operation, with wildcards for any of the three. An explicit deny always wins
 *              over an allow. Matching allow policies contribute field restrictions and a
 *              per-transaction record cap, which callers enforce through assertFieldsAllowed
 *              and assertRecordCount before touching data.
 *
 *              Security posture: inherited sharing. Policy metadata is read through
 *              AgentGovSelector in system mode so that a caller without access to the
 *              metadata cannot cause policies to be skipped.
 */
public inherited sharing class AgentGovPolicyEngine {
    /** @description Result of a policy evaluation. */
    public class PolicyResult {
        @AuraEnabled
        public Boolean allowed;
        @AuraEnabled
        public String denialReason;
        @AuraEnabled
        public Integer maxRecords;
        @AuraEnabled
        public List<String> restrictedFields;
    }

    /**
     * @description Builds an unrestricted result: allowed, no field restrictions, no record
     *              cap. Used when governance is switched off org-wide.
     * @return A permissive policy result
     */
    public static PolicyResult allowAll() {
        PolicyResult result = new PolicyResult();
        result.allowed = true;
        result.restrictedFields = new List<String>();
        return result;
    }

    /**
     * @description Evaluates whether an agent may perform an operation on an object.
     * @param registrationId The agent registration Id
     * @param objectName The object API name
     * @param operation One of the AgentGovConstants.ACTION_* values
     * @return The evaluation, including any field restrictions and record cap that apply
     */
    public static PolicyResult evaluatePolicy(Id registrationId, String objectName, String operation) {
        PolicyResult result = allowAll();

        if (!AgentGovSelector.isFrameworkEnabled()) {
            return result;
        }

        AgentGov_Registration__c registration = AgentGovSelector.getRegistrationById(registrationId);
        if (registration == null) {
            result.allowed = false;
            result.denialReason = AgentGovConstants.ERR_AGENT_NOT_FOUND;
            return result;
        }

        // A policy names the object it governs, so a blank object name matches nothing and
        // would skip every object-scoped rule. Denying is the safe reading: an evaluation that
        // cannot be performed is not an evaluation that passed.
        if (String.isBlank(objectName)) {
            result.allowed = false;
            result.denialReason = AgentGovConstants.ERR_INVALID_OBJECT_NAME;
            return result;
        }
        if (String.isBlank(operation)) {
            result.allowed = false;
            result.denialReason = AgentGovConstants.ERR_INVALID_ACTION_TYPE.trim();
            return result;
        }

        Boolean hasExplicitDeny = false;
        for (AgentGov_Policy__mdt policy : AgentGovSelector.getPoliciesForAgentType(registration.Agent_Type__c)) {
            if (String.isBlank(policy.Object_Name__c) || String.isBlank(policy.Operation__c)) {
                continue;
            }
            Boolean objectMatch =
                policy.Object_Name__c == AgentGovConstants.POLICY_WILDCARD ||
                (objectName != null && policy.Object_Name__c.equalsIgnoreCase(objectName));
            Boolean operationMatch =
                policy.Operation__c == AgentGovConstants.POLICY_WILDCARD ||
                (operation != null && policy.Operation__c.equalsIgnoreCase(operation));
            if (!objectMatch || !operationMatch) {
                continue;
            }

            if (policy.Is_Allowed__c == false) {
                hasExplicitDeny = true;
                result.denialReason = String.format(
                    AgentGovConstants.ERR_POLICY_VIOLATION,
                    new List<String>{ registration.Agent_Name__c, operation, objectName }
                );
                continue;
            }

            if (String.isNotBlank(policy.Field_Restrictions__c)) {
                for (String field : policy.Field_Restrictions__c.split(',')) {
                    if (String.isNotBlank(field)) {
                        result.restrictedFields.add(field.trim());
                    }
                }
            }
            if (policy.Max_Records_Per_Transaction__c != null) {
                Integer cap = (Integer) policy.Max_Records_Per_Transaction__c;
                if (result.maxRecords == null || cap < result.maxRecords) {
                    result.maxRecords = cap;
                }
            }
        }

        if (hasExplicitDeny) {
            result.allowed = false;
        }
        return result;
    }

    /**
     * @description Convenience check that returns only the allow/deny decision.
     * @param registrationId The agent registration Id
     * @param objectName The object API name
     * @param operation One of the AgentGovConstants.ACTION_* values
     * @return True when the operation is allowed
     */
    public static Boolean isActionAllowed(Id registrationId, String objectName, String operation) {
        return evaluatePolicy(registrationId, objectName, operation).allowed;
    }

    /**
     * @description Throws when any of the given fields is restricted by the evaluated policy.
     *              Restricted fields are denied rather than silently dropped, so an agent is
     *              never left believing a write succeeded when part of it was discarded.
     * @param policy The evaluation for this operation
     * @param fieldNames Field API names the agent is reading or writing
     * @throws AgentGovException POLICY_VIOLATION naming the restricted fields
     */
    public static void assertFieldsAllowed(PolicyResult policy, Set<String> fieldNames) {
        if (
            policy == null ||
            policy.restrictedFields == null ||
            policy.restrictedFields.isEmpty() ||
            fieldNames == null
        ) {
            return;
        }
        Set<String> restricted = new Set<String>();
        for (String field : policy.restrictedFields) {
            restricted.add(field.toLowerCase());
        }
        List<String> violations = new List<String>();
        for (String field : fieldNames) {
            if (field == null) {
                continue;
            }
            if (restricted.contains(field.toLowerCase())) {
                violations.add(field);
            }
        }
        if (!violations.isEmpty()) {
            violations.sort();
            throw new AgentGovException(
                AgentGovException.ErrorCode.POLICY_VIOLATION,
                AgentGovConstants.ERR_RESTRICTED_FIELDS + String.join(violations, ', ')
            );
        }
    }

    /**
     * @description Throws when a transaction touches more records than the policy allows.
     * @param policy The evaluation for this operation
     * @param recordCount Number of records in the transaction
     * @throws AgentGovException POLICY_VIOLATION when the cap is exceeded
     */
    public static void assertRecordCount(PolicyResult policy, Integer recordCount) {
        if (policy == null || policy.maxRecords == null || recordCount == null || recordCount <= policy.maxRecords) {
            return;
        }
        throw new AgentGovException(
            AgentGovException.ErrorCode.POLICY_VIOLATION,
            String.format(
                AgentGovConstants.ERR_MAX_RECORDS,
                new List<String>{ String.valueOf(policy.maxRecords), String.valueOf(recordCount) }
            )
        );
    }

    /**
     * @description Validates every policy record and lists configuration problems.
     * @return Human-readable issues; empty when all policies are valid
     */
    public static List<String> validatePolicies() {
        List<String> issues = new List<String>();
        for (AgentGov_Policy__mdt policy : AgentGovSelector.getPolicies()) {
            if (String.isBlank(policy.Object_Name__c)) {
                issues.add('Policy ' + policy.DeveloperName + ': Object_Name__c is blank.');
            }
            if (String.isBlank(policy.Operation__c)) {
                issues.add('Policy ' + policy.DeveloperName + ': Operation__c is blank.');
            }
            if (
                String.isNotBlank(policy.Operation__c) &&
                policy.Operation__c != AgentGovConstants.POLICY_WILDCARD &&
                !AgentGovConstants.VALID_OPERATIONS.contains(policy.Operation__c)
            ) {
                issues.add('Policy ' + policy.DeveloperName + ': Invalid operation "' + policy.Operation__c + '".');
            }
        }
        return issues;
    }
}
