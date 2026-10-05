/**
 * @description Evaluates the metadata-driven access policies before an agent acts.
 *
 *              Policies live in AgentGov_Policy__mdt and match on agent type, object, and
 *              operation, in any letter case. The agent type may be All for every type, and the
 *              object and the operation may be * for any. An explicit deny always wins over an
 *              allow. Matching allow policies contribute field restrictions and a
 *              per-transaction record cap, which callers enforce through assertFieldsAllowed
 *              and assertRecordCount before touching data.
 *
 *              Security posture: inherited sharing. Policy metadata is read through
 *              AgentGovSelector in system mode so that a caller without access to the
 *              metadata cannot cause policies to be skipped.
 */
public inherited sharing class AgentGovPolicyEngine {
    // Agent type stored values, keyed by the lower-case value and label. Read once per transaction.
    private static Map<String, String> agentTypesByName;

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
     * @description Resolves the agent type a policy names to the value stored on
     *              registrations. A policy may give the stored value, such as MCP_External, or
     *              the label shown on records, such as MCP External, in any letter case, and
     *              All for every type.
     * @param named The policy's Agent_Type__c
     * @return The stored value, AgentGovConstants.POLICY_ALL, or null when the text names no
     *         agent type
     */
    public static String resolveAgentType(String named) {
        if (String.isBlank(named)) {
            return null;
        }
        String key = named.trim().toLowerCase();
        if (key == AgentGovConstants.POLICY_ALL.toLowerCase()) {
            return AgentGovConstants.POLICY_ALL;
        }
        if (agentTypesByName == null) {
            agentTypesByName = new Map<String, String>();
            for (
                Schema.PicklistEntry entry : AgentGov_Registration__c.Agent_Type__c.getDescribe().getPicklistValues()
            ) {
                agentTypesByName.put(entry.getValue().toLowerCase(), entry.getValue());
                agentTypesByName.put(entry.getLabel().toLowerCase(), entry.getValue());
            }
        }
        return agentTypesByName.get(key);
    }

    /**
     * @description Reports whether a policy applies to agents of a type. The policy may name
     *              the type by its stored value or by the label shown on records, such as MCP
     *              External, so a deny policy written either way is enforced.
     * @param policy The policy record
     * @param agentType The Agent_Type__c stored on a registration
     * @return True when the policy names that type, or All
     */
    public static Boolean appliesToAgentType(AgentGov_Policy__mdt policy, String agentType) {
        String named = resolveAgentType(policy.Agent_Type__c);
        return named == AgentGovConstants.POLICY_ALL || (named != null && named == agentType);
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
     * @description Validates every policy record and lists configuration problems: a blank or
     *              unknown agent type, a blank object, and a blank or unknown operation. Names
     *              are checked in any letter case, as evaluation matches them.
     * @return Human-readable issues; empty when all policies are valid
     */
    public static List<String> validatePolicies() {
        List<String> issues = new List<String>();
        Set<String> operations = new Set<String>();
        for (String operation : AgentGovConstants.VALID_OPERATIONS) {
            operations.add(operation.toLowerCase());
        }
        for (AgentGov_Policy__mdt policy : AgentGovSelector.getPolicies()) {
            if (String.isBlank(policy.Agent_Type__c)) {
                issues.add('Policy ' + policy.DeveloperName + ': Agent_Type__c is blank.');
            } else if (resolveAgentType(policy.Agent_Type__c) == null) {
                issues.add('Policy ' + policy.DeveloperName + ': Unknown agent type "' + policy.Agent_Type__c + '".');
            }
            if (String.isBlank(policy.Object_Name__c)) {
                issues.add('Policy ' + policy.DeveloperName + ': Object_Name__c is blank.');
            }
            if (String.isBlank(policy.Operation__c)) {
                issues.add('Policy ' + policy.DeveloperName + ': Operation__c is blank.');
            }
            if (
                String.isNotBlank(policy.Operation__c) &&
                policy.Operation__c != AgentGovConstants.POLICY_WILDCARD &&
                !operations.contains(policy.Operation__c.toLowerCase())
            ) {
                issues.add('Policy ' + policy.DeveloperName + ': Invalid operation "' + policy.Operation__c + '".');
            }
        }
        return issues;
    }
}
