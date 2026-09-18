/**
 * @description Governed CRUD proxy for external and MCP agents.
 *
 *              Agents call these endpoints instead of the standard REST API. Each request is
 *              authenticated, run through the circuit breaker and policy engine, checked for
 *              record conflicts, charged to the agent's budget by the number of records it
 *              touches, executed, and logged. Budget is therefore consumed by the real record
 *              count, not by a self-reported estimate.
 *
 *              Endpoints (POST): /query, /create, /update, /delete, /upsert.
 *
 *              Security posture: with sharing, and every query and DML statement issued on
 *              the agent's behalf runs with AccessLevel.USER_MODE. The calling user's object
 *              permissions, field-level security, and sharing rules apply to customer data.
 *              /query accepts a structured request compiled by AgentGovQueryBuilder rather
 *              than SOQL text, so injection and policy bypass through relationship paths or
 *              subqueries are impossible by construction. Framework bookkeeping (budgets,
 *              logs, breaker state) runs in system mode through the service classes.
 */
@RestResource(urlMapping='/agentgov-proxy/*')
global with sharing class AgentGovProxyApi {
    private static final String PATH_QUERY = '/query';
    private static final String PATH_CREATE = '/create';
    private static final String PATH_UPDATE = '/update';
    private static final String PATH_DELETE = '/delete';
    private static final String PATH_UPSERT = '/upsert';
    private static final Set<String> KNOWN_PATHS = new Set<String>{
        PATH_QUERY,
        PATH_CREATE,
        PATH_UPDATE,
        PATH_DELETE,
        PATH_UPSERT
    };
    private static final Set<AgentGovException.ErrorCode> DENIAL_CODES = new Set<AgentGovException.ErrorCode>{
        AgentGovException.ErrorCode.CIRCUIT_BREAKER_OPEN,
        AgentGovException.ErrorCode.POLICY_VIOLATION,
        AgentGovException.ErrorCode.BUDGET_EXCEEDED,
        AgentGovException.ErrorCode.RECORD_LOCKED,
        AgentGovException.ErrorCode.ACCESS_DENIED
    };
    private static final String JSON_ATTRIBUTES_KEY = 'attributes';

    // Set by the handler in progress so that a denial can be logged with its context.
    private static String currentOperation;
    private static String currentObject;

    /** Per-record outcome of a write. */
    private class WriteSummary {
        private Integer successCount = 0;
        private List<Map<String, Object>> results = new List<Map<String, Object>>();
    }

    /** @description Routes POST requests to the proxy handlers. */
    @HttpPost
    global static void doPost() {
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;
        String correlationId = AgentGovRestResponder.correlationId(request);
        AgentGov_Registration__c registration;
        currentOperation = null;
        currentObject = null;

        try {
            String path = request.requestURI.substringAfter(AgentGovConstants.REST_PROXY_BASE_PATH.removeEnd('/'));
            if (!KNOWN_PATHS.contains(path)) {
                AgentGovRestResponder.notFound(response, path, correlationId);
                return;
            }
            Map<String, Object> body = parseBody(request);
            registration = AgentGovRestAuth.resolveRegistration(request, body);
            // A Blocked agent whose cooldown has elapsed is admitted past the status check so
            // the breaker can readmit it; tripping leaves the agent Blocked, and refusing here
            // would lock a REST-only agent out for good. Nothing is written at this point: the
            // transition and the probe claim happen together under the row lock taken by
            // runGovernancePipeline's allowRequest call.
            registration = AgentGovRestAuth.requireActive(
                registration,
                true,
                AgentGovCircuitBreaker.mayProbe(registration)
            );

            Map<String, Object> payload;
            switch on path {
                when '/query' {
                    payload = handleQuery(registration, body);
                }
                when '/create' {
                    payload = handleCreate(registration, body);
                }
                when '/update' {
                    payload = handleUpdate(registration, body);
                }
                when '/delete' {
                    payload = handleDelete(registration, body);
                }
                when else {
                    payload = handleUpsert(registration, body);
                }
            }
            AgentGovRestResponder.success(response, 200, payload, correlationId);
        } catch (AgentGovException e) {
            logDenial(registration, e);
            AgentGovRestResponder.error(response, e, correlationId);
        } catch (Exception e) {
            AgentGovRestResponder.internalError(response, e, correlationId, registration?.Id);
        }
    }

    // --- Handlers ---

    private static Map<String, Object> handleQuery(AgentGov_Registration__c registration, Map<String, Object> body) {
        AgentGovQueryBuilder.QueryRequest queryRequest = AgentGovQueryBuilder.parse(body);
        Schema.DescribeSObjectResult describe = AgentGovQueryBuilder.describe(queryRequest.objectName);
        AgentGovPolicyEngine.PolicyResult policy = runGovernancePipeline(
            registration,
            describe.getName(),
            AgentGovConstants.ACTION_QUERY
        );
        AgentGovQueryBuilder.BuiltQuery built = AgentGovQueryBuilder.build(queryRequest, describe, policy.maxRecords);
        AgentGovPolicyEngine.assertFieldsAllowed(policy, built.referencedFields);

        AgentGovBudgetManager.BudgetResult budget = charge(registration, AgentGovConstants.LIMIT_SOQL_QUERIES, 1);
        List<SObject> results = AgentGovQueryBuilder.execute(built);

        AgentGovTriggerHandler.logAction(
            registration.Id,
            AgentGovConstants.ACTION_QUERY,
            describe.getName(),
            null,
            AgentGovConstants.ACTION_SUCCESS,
            results.size() + ' records returned'
        );
        recordOutcome(registration, true);

        return new Map<String, Object>{
            'totalSize' => results.size(),
            'records' => results,
            'budgetStatus' => budget.budgetStatus,
            'remainingBudget' => AgentGovRestResponder.remainingBudget(budget)
        };
    }

    private static Map<String, Object> handleCreate(AgentGov_Registration__c registration, Map<String, Object> body) {
        List<Object> rawRecords = requireRecords(body);
        Schema.DescribeSObjectResult describe = AgentGovQueryBuilder.describe(requireObjectName(body));
        AgentGovPolicyEngine.PolicyResult policy = runGovernancePipeline(
            registration,
            describe.getName(),
            AgentGovConstants.ACTION_CREATE
        );
        AgentGovPolicyEngine.assertRecordCount(policy, rawRecords.size());

        Set<String> fieldsUsed = new Set<String>();
        List<SObject> records = buildSObjects(describe, rawRecords, fieldsUsed, false);
        AgentGovPolicyEngine.assertFieldsAllowed(policy, fieldsUsed);
        assertFieldAccess(AccessType.CREATABLE, records, describe.getName(), 'create');

        AgentGovBudgetManager.BudgetResult budget = consumeDml(registration, records.size());
        WriteSummary summary = summarizeSaveResults(Database.insert(records, false, AccessLevel.USER_MODE));
        return finishWrite(
            registration,
            AgentGovConstants.ACTION_CREATE,
            describe.getName(),
            summary,
            records.size(),
            budget,
            'created'
        );
    }

    private static Map<String, Object> handleUpdate(AgentGov_Registration__c registration, Map<String, Object> body) {
        List<Object> rawRecords = requireRecords(body);
        Schema.DescribeSObjectResult describe = AgentGovQueryBuilder.describe(requireObjectName(body));
        AgentGovPolicyEngine.PolicyResult policy = runGovernancePipeline(
            registration,
            describe.getName(),
            AgentGovConstants.ACTION_UPDATE
        );
        AgentGovPolicyEngine.assertRecordCount(policy, rawRecords.size());

        Set<String> fieldsUsed = new Set<String>();
        List<SObject> records = buildSObjects(describe, rawRecords, fieldsUsed, true);
        AgentGovPolicyEngine.assertFieldsAllowed(policy, fieldsUsed);
        assertNoConflicts(registration, records, describe.getName());
        assertFieldAccess(AccessType.UPDATABLE, records, describe.getName(), 'update');

        AgentGovBudgetManager.BudgetResult budget = consumeDml(registration, records.size());
        WriteSummary summary = summarizeSaveResults(Database.update(records, false, AccessLevel.USER_MODE));
        return finishWrite(
            registration,
            AgentGovConstants.ACTION_UPDATE,
            describe.getName(),
            summary,
            records.size(),
            budget,
            'updated'
        );
    }

    private static Map<String, Object> handleDelete(AgentGov_Registration__c registration, Map<String, Object> body) {
        Schema.DescribeSObjectResult describe = AgentGovQueryBuilder.describe(requireObjectName(body));
        Object rawIds = body.get('ids');
        if (!(rawIds instanceof List<Object>) || ((List<Object>) rawIds).isEmpty()) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_NO_IDS);
        }
        AgentGovPolicyEngine.PolicyResult policy = runGovernancePipeline(
            registration,
            describe.getName(),
            AgentGovConstants.ACTION_DELETE
        );
        List<Id> ids = new List<Id>();
        for (Object rawId : (List<Object>) rawIds) {
            ids.add(parseId(rawId, describe));
        }
        AgentGovPolicyEngine.assertRecordCount(policy, ids.size());
        assertNoConflictsForIds(registration, ids, describe.getName());

        AgentGovBudgetManager.BudgetResult budget = consumeDml(registration, ids.size());
        WriteSummary summary = summarizeDeleteResults(Database.delete(ids, false, AccessLevel.USER_MODE), ids);
        return finishWrite(
            registration,
            AgentGovConstants.ACTION_DELETE,
            describe.getName(),
            summary,
            ids.size(),
            budget,
            'deleted'
        );
    }

    private static Map<String, Object> handleUpsert(AgentGov_Registration__c registration, Map<String, Object> body) {
        List<Object> rawRecords = requireRecords(body);
        Schema.DescribeSObjectResult describe = AgentGovQueryBuilder.describe(requireObjectName(body));
        AgentGovPolicyEngine.PolicyResult policy = runGovernancePipeline(
            registration,
            describe.getName(),
            AgentGovConstants.ACTION_UPSERT
        );
        AgentGovPolicyEngine.assertRecordCount(policy, rawRecords.size());

        Schema.SObjectField externalIdField;
        String externalIdFieldName = (String) body.get('externalIdField');
        if (String.isNotBlank(externalIdFieldName)) {
            String apiName = AgentGovQueryBuilder.resolveField(
                externalIdFieldName,
                describe.fields.getMap(),
                describe.getName()
            );
            externalIdField = describe.fields.getMap().get(apiName.toLowerCase());
            if (!externalIdField.getDescribe().isExternalId() && !externalIdField.getDescribe().isIdLookup()) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.INVALID_INPUT,
                    'externalIdField must be an External ID field: ' + apiName
                );
            }
        }

        Set<String> fieldsUsed = new Set<String>();
        // Upsert requires a list of the concrete SObject type, not a generic SObject list.
        List<SObject> records = (List<SObject>) Type.forName('List<' + describe.getName() + '>').newInstance();
        records.addAll(buildSObjects(describe, rawRecords, fieldsUsed, false));
        AgentGovPolicyEngine.assertFieldsAllowed(policy, fieldsUsed);
        assertNoConflicts(registration, records, describe.getName());
        assertFieldAccess(AccessType.UPSERTABLE, records, describe.getName(), 'upsert');

        AgentGovBudgetManager.BudgetResult budget = consumeDml(registration, records.size());
        List<Database.UpsertResult> results = externalIdField != null
            ? Database.upsert(records, externalIdField, false, AccessLevel.USER_MODE)
            : Database.upsert(records, false, AccessLevel.USER_MODE);
        return finishWrite(
            registration,
            AgentGovConstants.ACTION_UPSERT,
            describe.getName(),
            summarizeUpsertResults(results),
            records.size(),
            budget,
            'upserted'
        );
    }

    // --- Pipeline helpers ---

    private static AgentGovPolicyEngine.PolicyResult runGovernancePipeline(
        AgentGov_Registration__c registration,
        String objectName,
        String operation
    ) {
        currentOperation = operation;
        currentObject = objectName;

        // Is_Enabled__c is the documented emergency bypass: with governance off the breaker and
        // the policy engine are skipped here, and charge() and assertNoConflicts() below skip
        // the budget and conflict checks, so a migration is not blocked by a half-tripped
        // framework. Auditing continues regardless.
        if (!AgentGovSelector.isFrameworkEnabled()) {
            return AgentGovPolicyEngine.allowAll();
        }

        if (!AgentGovCircuitBreaker.allowRequest(registration.Id)) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.CIRCUIT_BREAKER_OPEN,
                AgentGovConstants.ERR_CIRCUIT_BREAKER_OPEN
            );
        }
        AgentGovPolicyEngine.PolicyResult policy = AgentGovPolicyEngine.evaluatePolicy(
            registration.Id,
            objectName,
            operation
        );
        if (!policy.allowed) {
            throw new AgentGovException(AgentGovException.ErrorCode.POLICY_VIOLATION, policy.denialReason);
        }
        return policy;
    }

    /**
     * Charges the agent for work the proxy is about to do. With governance switched off the
     * budget is read rather than consumed, so the response still reports a truthful remaining
     * balance while the emergency bypass keeps the request from being refused.
     */
    /**
     * Records a breaker outcome unless governance is switched off. During an emergency bypass
     * a failure must not trip the breaker: tripping sets Status__c to Blocked, and the status
     * check runs before the bypass does, so the agent would be locked out by the very switch
     * meant to unblock it.
     */
    private static void recordOutcome(AgentGov_Registration__c registration, Boolean succeeded) {
        if (!AgentGovSelector.isFrameworkEnabled()) {
            return;
        }
        AgentGovCircuitBreaker.recordOutcomes(new Map<Id, Boolean>{ registration.Id => succeeded });
    }

    private static AgentGovBudgetManager.BudgetResult charge(
        AgentGov_Registration__c registration,
        String limitType,
        Integer amount
    ) {
        if (!AgentGovSelector.isFrameworkEnabled()) {
            return AgentGovBudgetManager.checkBudget(registration.Id);
        }
        return AgentGovBudgetManager.consumeBudget(registration.Id, limitType, amount);
    }

    private static AgentGovBudgetManager.BudgetResult consumeDml(
        AgentGov_Registration__c registration,
        Integer recordCount
    ) {
        return charge(registration, AgentGovConstants.LIMIT_DML_OPERATIONS, recordCount);
    }

    private static void assertNoConflicts(
        AgentGov_Registration__c registration,
        List<SObject> records,
        String objectName
    ) {
        List<Id> ids = new List<Id>();
        for (SObject record : records) {
            if (record.Id != null) {
                ids.add(record.Id);
            }
        }
        assertNoConflictsForIds(registration, ids, objectName);
    }

    /**
     * Conflict check for a list of record Ids. Every handler routes through here so the
     * Is_Enabled__c bypass is honoured uniformly; /delete used to call the resolver directly
     * and kept enforcing conflicts during an emergency bypass.
     */
    private static void assertNoConflictsForIds(
        AgentGov_Registration__c registration,
        List<Id> recordIds,
        String objectName
    ) {
        if (!AgentGovSelector.isFrameworkEnabled()) {
            return;
        }
        for (Id recordId : recordIds) {
            AgentGovConflictResolver.assertNoConflict(registration.Id, recordId, objectName);
        }
    }

    /**
     * Denies the whole request when the calling user lacks field-level access to any field
     * it is writing. Denying is deliberate: silently dropping fields would let the agent
     * believe a write succeeded in full.
     */
    private static void assertFieldAccess(
        AccessType accessType,
        List<SObject> records,
        String objectName,
        String verb
    ) {
        SObjectAccessDecision decision;
        try {
            decision = Security.stripInaccessible(accessType, records, true);
        } catch (Exception e) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.ACCESS_DENIED,
                String.format(
                    AgentGovConstants.ERR_FIELDS_NOT_ACCESSIBLE,
                    new List<String>{ verb, objectName, e.getMessage() }
                )
            );
        }
        Map<String, Set<String>> removed = decision.getRemovedFields();
        if (removed.isEmpty()) {
            return;
        }
        List<String> fields = new List<String>();
        for (Set<String> objectFields : removed.values()) {
            fields.addAll(objectFields);
        }
        fields.sort();
        throw new AgentGovException(
            AgentGovException.ErrorCode.ACCESS_DENIED,
            String.format(
                AgentGovConstants.ERR_FIELDS_NOT_ACCESSIBLE,
                new List<String>{ verb, objectName, String.join(fields, ', ') }
            )
        );
    }

    private static Map<String, Object> finishWrite(
        AgentGov_Registration__c registration,
        String action,
        String objectName,
        WriteSummary summary,
        Integer recordCount,
        AgentGovBudgetManager.BudgetResult budget,
        String verb
    ) {
        Boolean anySucceeded = summary.successCount > 0;
        AgentGovTriggerHandler.logAction(
            registration.Id,
            action,
            objectName,
            null,
            anySucceeded ? AgentGovConstants.ACTION_SUCCESS : AgentGovConstants.ACTION_FAILURE,
            summary.successCount + '/' + recordCount + ' records ' + verb
        );
        if (anySucceeded) {
            recordOutcome(registration, true);
        } else {
            recordOutcome(registration, false);
        }
        return new Map<String, Object>{
            'allSucceeded' => summary.successCount == recordCount,
            'recordsProcessed' => recordCount,
            'recordsSucceeded' => summary.successCount,
            'results' => summary.results,
            'budgetStatus' => budget.budgetStatus,
            'remainingBudget' => AgentGovRestResponder.remainingBudget(budget)
        };
    }

    private static void logDenial(AgentGov_Registration__c registration, AgentGovException e) {
        if (registration == null || currentOperation == null || !DENIAL_CODES.contains(e.getErrorCode())) {
            return;
        }
        AgentGovTriggerHandler.logAction(
            registration.Id,
            currentOperation,
            currentObject,
            null,
            AgentGovConstants.ACTION_DENIED,
            e.getMessage()
        );
    }

    // --- Input helpers ---

    private static Map<String, Object> parseBody(RestRequest request) {
        if (request.requestBody == null || String.isBlank(request.requestBody.toString())) {
            return new Map<String, Object>();
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(request.requestBody.toString());
        } catch (JSONException e) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                'Request body must be a JSON object.'
            );
        }
        if (parsed instanceof Map<String, Object>) {
            return (Map<String, Object>) parsed;
        }
        throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, 'Request body must be a JSON object.');
    }

    private static String requireObjectName(Map<String, Object> body) {
        String objectName = (String) body.get('objectName');
        if (String.isBlank(objectName)) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                AgentGovConstants.ERR_INVALID_OBJECT_NAME
            );
        }
        return objectName;
    }

    private static List<Object> requireRecords(Map<String, Object> body) {
        Object rawRecords = body.get('records');
        if (!(rawRecords instanceof List<Object>) || ((List<Object>) rawRecords).isEmpty()) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_NO_RECORDS);
        }
        return (List<Object>) rawRecords;
    }

    private static List<SObject> buildSObjects(
        Schema.DescribeSObjectResult describe,
        List<Object> rawRecords,
        Set<String> fieldsUsed,
        Boolean requireId
    ) {
        Map<String, Schema.SObjectField> fieldMap = describe.fields.getMap();
        List<SObject> records = new List<SObject>();
        for (Object rawRecord : rawRecords) {
            if (!(rawRecord instanceof Map<String, Object>)) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.INVALID_INPUT,
                    'Each record must be a JSON object.'
                );
            }
            Map<String, Object> values = (Map<String, Object>) rawRecord;
            SObject record = describe.getSObjectType().newSObject();
            Boolean hasId = false;
            for (String fieldName : values.keySet()) {
                if (fieldName.equalsIgnoreCase(JSON_ATTRIBUTES_KEY)) {
                    continue;
                }
                if (fieldName.equalsIgnoreCase('Id')) {
                    record.Id = parseId(values.get(fieldName), describe);
                    hasId = true;
                    continue;
                }
                String apiName = AgentGovQueryBuilder.resolveField(fieldName, fieldMap, describe.getName());
                fieldsUsed.add(apiName);
                Schema.DisplayType fieldType = fieldMap.get(apiName.toLowerCase()).getDescribe().getType();
                record.put(apiName, AgentGovQueryBuilder.convertFieldValue(values.get(fieldName), fieldType));
            }
            if (requireId && !hasId) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.INVALID_INPUT,
                    AgentGovConstants.ERR_RECORD_ID_REQUIRED
                );
            }
            records.add(record);
        }
        return records;
    }

    private static Id parseId(Object rawId, Schema.DescribeSObjectResult describe) {
        Id recordId;
        try {
            recordId = Id.valueOf(String.valueOf(rawId));
        } catch (Exception e) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                AgentGovConstants.ERR_INVALID_RECORD_ID + String.valueOf(rawId)
            );
        }
        if (recordId.getSObjectType() != describe.getSObjectType()) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                String.format(
                    AgentGovConstants.ERR_ID_TYPE_MISMATCH,
                    new List<String>{ String.valueOf(recordId), describe.getName() }
                )
            );
        }
        return recordId;
    }

    // --- Result helpers ---

    private static WriteSummary summarizeSaveResults(List<Database.SaveResult> results) {
        WriteSummary summary = new WriteSummary();
        for (Database.SaveResult result : results) {
            Map<String, Object> entry = new Map<String, Object>{ 'success' => result.isSuccess() };
            if (result.isSuccess()) {
                entry.put('id', result.getId());
                summary.successCount++;
            } else {
                entry.put('errors', errorMessages(result.getErrors()));
            }
            summary.results.add(entry);
        }
        return summary;
    }

    private static WriteSummary summarizeUpsertResults(List<Database.UpsertResult> results) {
        WriteSummary summary = new WriteSummary();
        for (Database.UpsertResult result : results) {
            Map<String, Object> entry = new Map<String, Object>{
                'success' => result.isSuccess(),
                'created' => result.isCreated()
            };
            if (result.isSuccess()) {
                entry.put('id', result.getId());
                summary.successCount++;
            } else {
                entry.put('errors', errorMessages(result.getErrors()));
            }
            summary.results.add(entry);
        }
        return summary;
    }

    private static WriteSummary summarizeDeleteResults(List<Database.DeleteResult> results, List<Id> ids) {
        WriteSummary summary = new WriteSummary();
        for (Integer i = 0; i < results.size(); i++) {
            Map<String, Object> entry = new Map<String, Object>{ 'success' => results[i].isSuccess(), 'id' => ids[i] };
            if (results[i].isSuccess()) {
                summary.successCount++;
            } else {
                entry.put('errors', errorMessages(results[i].getErrors()));
            }
            summary.results.add(entry);
        }
        return summary;
    }

    // Per-record database errors are the agent's own validation feedback and are safe to return.
    private static List<String> errorMessages(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error error : errors) {
            messages.add(error.getMessage());
        }
        return messages;
    }
}
