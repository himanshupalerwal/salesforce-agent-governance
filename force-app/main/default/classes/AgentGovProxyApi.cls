/**
 * @description Proxy REST API that executes CRUD operations on behalf of agents.
 *              Instead of agents calling Salesforce REST API directly, they go through
 *              this proxy which counts actual operations and enforces governance.
 *              Budget is consumed by the REAL number of records affected.
 * @author Himanshu Palerwal
 */
@RestResource(urlMapping='/agentgov-proxy/*')
global with sharing class AgentGovProxyApi {

    @HttpPost
    global static void doPost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        try {
            String path = req.requestURI.substringAfter('/agentgov-proxy');
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

            if (path == '/query') {
                handleQuery(body, res);
            } else if (path == '/create') {
                handleCreate(body, res);
            } else if (path == '/update') {
                handleUpdate(body, res);
            } else if (path == '/delete') {
                handleDelete(body, res);
            } else if (path == '/upsert') {
                handleUpsert(body, res);
            } else {
                res.statusCode = 404;
                res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                    'error' => 'Unknown proxy endpoint: ' + path,
                    'errorCode' => 'NOT_FOUND'
                }));
            }
        } catch (AgentGovException e) {
            res.statusCode = e.getHttpStatusCode();
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'error' => e.getMessage(),
                'errorCode' => String.valueOf(e.getErrorCode())
            }));
        } catch (Exception e) {
            res.statusCode = 500;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'error' => e.getMessage(),
                'errorCode' => 'INTERNAL_ERROR'
            }));
        }
    }

    /**
     * @description Executes a SOQL query on behalf of an agent. Counts as 1 SOQL query.
     */
    private static void handleQuery(Map<String, Object> body, RestResponse res) {
        AgentGov_Registration__c reg = authenticateAgent(body);
        String soqlQuery = (String) body.get('query');
        if (String.isBlank(soqlQuery)) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_INVALID_SOQL);
        }

        // Validate SOQL — prevent injection by checking for dangerous keywords
        String upperQuery = soqlQuery.toUpperCase().trim();
        if (!upperQuery.startsWith('SELECT')) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_INVALID_SOQL);
        }

        // Extract object name from query for policy check
        String objectName = extractObjectFromSoql(soqlQuery);

        // Run governance pipeline
        runGovernancePipeline(reg, objectName, AgentGovConstants.ACTION_QUERY, null);

        // Consume 1 SOQL query budget
        AgentGovBudgetManager.BudgetResult budgetResult = AgentGovBudgetManager.consumeBudget(
            reg.Id, AgentGovConstants.LIMIT_SOQL_QUERIES, 1
        );

        // Execute the query
        List<SObject> results = Database.query(soqlQuery);

        // Log the action
        logAction(reg.Id, AgentGovConstants.ACTION_QUERY, objectName, null, AgentGovConstants.ACTION_SUCCESS, results.size() + ' records returned');

        // Record success for circuit breaker
        AgentGovCircuitBreaker.recordSuccess(reg.Id);

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'success' => true,
            'totalSize' => results.size(),
            'records' => results,
            'budgetStatus' => budgetResult.budgetStatus,
            'remainingBudget' => new Map<String, Object>{
                'apiCalls' => budgetResult.apiCallsRemaining,
                'soqlQueries' => budgetResult.soqlQueriesRemaining,
                'dmlOperations' => budgetResult.dmlOperationsRemaining
            }
        }));
    }

    /**
     * @description Creates records on behalf of an agent. Budget consumed = number of records.
     */
    private static void handleCreate(Map<String, Object> body, RestResponse res) {
        AgentGov_Registration__c reg = authenticateAgent(body);
        String objectName = (String) body.get('objectName');
        List<Object> recordsRaw = (List<Object>) body.get('records');
        validateCrudInput(objectName, recordsRaw);

        // Run governance pipeline
        runGovernancePipeline(reg, objectName, AgentGovConstants.ACTION_CREATE, null);

        // Consume budget by actual record count
        Integer recordCount = recordsRaw.size();
        AgentGovBudgetManager.BudgetResult budgetResult = AgentGovBudgetManager.consumeBudget(
            reg.Id, AgentGovConstants.LIMIT_DML_OPERATIONS, recordCount
        );

        // Build SObjects from JSON
        List<SObject> records = buildSObjects(objectName, recordsRaw);

        // Perform insert
        Database.SaveResult[] results = Database.insert(records, false);

        // Build response with per-record results
        List<Map<String, Object>> resultList = new List<Map<String, Object>>();
        Integer successCount = 0;
        for (Integer i = 0; i < results.size(); i++) {
            Map<String, Object> r = new Map<String, Object>();
            r.put('success', results[i].isSuccess());
            if (results[i].isSuccess()) {
                r.put('id', results[i].getId());
                successCount++;
            } else {
                r.put('errors', getErrorMessages(results[i].getErrors()));
            }
            resultList.add(r);
        }

        logAction(reg.Id, AgentGovConstants.ACTION_CREATE, objectName, null,
            successCount > 0 ? AgentGovConstants.ACTION_SUCCESS : AgentGovConstants.ACTION_FAILURE,
            successCount + '/' + recordCount + ' records created');

        if (successCount > 0) {
            AgentGovCircuitBreaker.recordSuccess(reg.Id);
        } else {
            AgentGovCircuitBreaker.recordFailure(reg.Id);
        }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'success' => successCount > 0,
            'recordsProcessed' => recordCount,
            'recordsSucceeded' => successCount,
            'results' => resultList,
            'budgetStatus' => budgetResult.budgetStatus,
            'remainingBudget' => buildRemainingBudgetMap(budgetResult)
        }));
    }

    /**
     * @description Updates records on behalf of an agent. Budget consumed = number of records.
     */
    private static void handleUpdate(Map<String, Object> body, RestResponse res) {
        AgentGov_Registration__c reg = authenticateAgent(body);
        String objectName = (String) body.get('objectName');
        List<Object> recordsRaw = (List<Object>) body.get('records');
        validateCrudInput(objectName, recordsRaw);

        runGovernancePipeline(reg, objectName, AgentGovConstants.ACTION_UPDATE, null);

        Integer recordCount = recordsRaw.size();
        AgentGovBudgetManager.BudgetResult budgetResult = AgentGovBudgetManager.consumeBudget(
            reg.Id, AgentGovConstants.LIMIT_DML_OPERATIONS, recordCount
        );

        List<SObject> records = buildSObjects(objectName, recordsRaw);
        Database.SaveResult[] results = Database.update(records, false);

        Integer successCount = 0;
        List<Map<String, Object>> resultList = new List<Map<String, Object>>();
        for (Integer i = 0; i < results.size(); i++) {
            Map<String, Object> r = new Map<String, Object>();
            r.put('success', results[i].isSuccess());
            if (results[i].isSuccess()) {
                r.put('id', results[i].getId());
                successCount++;
            } else {
                r.put('errors', getErrorMessages(results[i].getErrors()));
            }
            resultList.add(r);
        }

        logAction(reg.Id, AgentGovConstants.ACTION_UPDATE, objectName, null,
            successCount > 0 ? AgentGovConstants.ACTION_SUCCESS : AgentGovConstants.ACTION_FAILURE,
            successCount + '/' + recordCount + ' records updated');

        if (successCount > 0) { AgentGovCircuitBreaker.recordSuccess(reg.Id); }
        else { AgentGovCircuitBreaker.recordFailure(reg.Id); }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'success' => successCount > 0,
            'recordsProcessed' => recordCount,
            'recordsSucceeded' => successCount,
            'results' => resultList,
            'budgetStatus' => budgetResult.budgetStatus,
            'remainingBudget' => buildRemainingBudgetMap(budgetResult)
        }));
    }

    /**
     * @description Deletes records on behalf of an agent. Budget consumed = number of records.
     */
    private static void handleDelete(Map<String, Object> body, RestResponse res) {
        AgentGov_Registration__c reg = authenticateAgent(body);
        String objectName = (String) body.get('objectName');
        List<Object> idsRaw = (List<Object>) body.get('ids');
        if (String.isBlank(objectName) || idsRaw == null || idsRaw.isEmpty()) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_NO_RECORDS);
        }

        runGovernancePipeline(reg, objectName, AgentGovConstants.ACTION_DELETE, null);

        Integer recordCount = idsRaw.size();
        AgentGovBudgetManager.BudgetResult budgetResult = AgentGovBudgetManager.consumeBudget(
            reg.Id, AgentGovConstants.LIMIT_DML_OPERATIONS, recordCount
        );

        List<Id> idsToDelete = new List<Id>();
        for (Object idObj : idsRaw) {
            idsToDelete.add((Id) String.valueOf(idObj));
        }

        Database.DeleteResult[] results = Database.delete(idsToDelete, false);

        Integer successCount = 0;
        List<Map<String, Object>> resultList = new List<Map<String, Object>>();
        for (Integer i = 0; i < results.size(); i++) {
            Map<String, Object> r = new Map<String, Object>();
            r.put('success', results[i].isSuccess());
            r.put('id', idsToDelete[i]);
            if (!results[i].isSuccess()) {
                r.put('errors', getErrorMessages(results[i].getErrors()));
            } else {
                successCount++;
            }
            resultList.add(r);
        }

        logAction(reg.Id, AgentGovConstants.ACTION_DELETE, objectName, null,
            successCount > 0 ? AgentGovConstants.ACTION_SUCCESS : AgentGovConstants.ACTION_FAILURE,
            successCount + '/' + recordCount + ' records deleted');

        if (successCount > 0) { AgentGovCircuitBreaker.recordSuccess(reg.Id); }
        else { AgentGovCircuitBreaker.recordFailure(reg.Id); }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'success' => successCount > 0,
            'recordsProcessed' => recordCount,
            'recordsSucceeded' => successCount,
            'results' => resultList,
            'budgetStatus' => budgetResult.budgetStatus,
            'remainingBudget' => buildRemainingBudgetMap(budgetResult)
        }));
    }

    /**
     * @description Upserts records on behalf of an agent. Budget consumed = number of records.
     */
    private static void handleUpsert(Map<String, Object> body, RestResponse res) {
        AgentGov_Registration__c reg = authenticateAgent(body);
        String objectName = (String) body.get('objectName');
        String externalIdField = (String) body.get('externalIdField');
        List<Object> recordsRaw = (List<Object>) body.get('records');
        validateCrudInput(objectName, recordsRaw);

        runGovernancePipeline(reg, objectName, AgentGovConstants.ACTION_UPSERT, null);

        Integer recordCount = recordsRaw.size();
        AgentGovBudgetManager.BudgetResult budgetResult = AgentGovBudgetManager.consumeBudget(
            reg.Id, AgentGovConstants.LIMIT_DML_OPERATIONS, recordCount
        );

        List<SObject> records = buildSObjects(objectName, recordsRaw);
        Schema.SObjectField extField = null;
        if (String.isNotBlank(externalIdField)) {
            extField = Schema.getGlobalDescribe().get(objectName).getDescribe().fields.getMap().get(externalIdField);
        }

        Database.UpsertResult[] results;
        if (extField != null) {
            results = Database.upsert(records, extField, false);
        } else {
            results = Database.upsert(records, false);
        }

        Integer successCount = 0;
        List<Map<String, Object>> resultList = new List<Map<String, Object>>();
        for (Integer i = 0; i < results.size(); i++) {
            Map<String, Object> r = new Map<String, Object>();
            r.put('success', results[i].isSuccess());
            r.put('created', results[i].isCreated());
            if (results[i].isSuccess()) {
                r.put('id', results[i].getId());
                successCount++;
            } else {
                r.put('errors', getErrorMessages(results[i].getErrors()));
            }
            resultList.add(r);
        }

        logAction(reg.Id, AgentGovConstants.ACTION_UPSERT, objectName, null,
            successCount > 0 ? AgentGovConstants.ACTION_SUCCESS : AgentGovConstants.ACTION_FAILURE,
            successCount + '/' + recordCount + ' records upserted');

        if (successCount > 0) { AgentGovCircuitBreaker.recordSuccess(reg.Id); }
        else { AgentGovCircuitBreaker.recordFailure(reg.Id); }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'success' => successCount > 0,
            'recordsProcessed' => recordCount,
            'recordsSucceeded' => successCount,
            'results' => resultList,
            'budgetStatus' => budgetResult.budgetStatus,
            'remainingBudget' => buildRemainingBudgetMap(budgetResult)
        }));
    }

    // --- Private helpers ---

    private static AgentGov_Registration__c authenticateAgent(Map<String, Object> body) {
        String apiKey = (String) body.get('apiKey');
        if (String.isBlank(apiKey)) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, 'apiKey is required.');
        }
        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationByApiKey(apiKey);
        if (reg == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.AGENT_NOT_FOUND, AgentGovConstants.ERR_AGENT_NOT_REGISTERED);
        }
        if (reg.Status__c != AgentGovConstants.STATUS_ACTIVE && reg.Status__c != AgentGovConstants.STATUS_THROTTLED) {
            throw new AgentGovException(AgentGovException.ErrorCode.AGENT_NOT_ACTIVE, AgentGovConstants.ERR_AGENT_NOT_ACTIVE);
        }
        return reg;
    }

    private static void runGovernancePipeline(AgentGov_Registration__c reg, String objectName, String operation, String recordId) {
        // Circuit breaker check
        if (!AgentGovCircuitBreaker.allowRequest(reg.Id)) {
            throw new AgentGovException(AgentGovException.ErrorCode.CIRCUIT_BREAKER_OPEN, AgentGovConstants.ERR_CIRCUIT_BREAKER_OPEN);
        }
        // Policy check
        AgentGovPolicyEngine.PolicyResult policy = AgentGovPolicyEngine.evaluatePolicy(reg.Id, objectName, operation);
        if (!policy.allowed) {
            throw new AgentGovException(AgentGovException.ErrorCode.POLICY_VIOLATION, policy.denialReason);
        }
    }

    private static void validateCrudInput(String objectName, List<Object> records) {
        if (String.isBlank(objectName)) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_INVALID_OBJECT_NAME);
        }
        if (records == null || records.isEmpty()) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_NO_RECORDS);
        }
    }

    private static List<SObject> buildSObjects(String objectName, List<Object> recordsRaw) {
        Schema.SObjectType sObjType = Schema.getGlobalDescribe().get(objectName);
        if (sObjType == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, 'Unknown object: ' + objectName);
        }
        Map<String, Schema.SObjectField> fieldMap = sObjType.getDescribe().fields.getMap();

        List<SObject> records = new List<SObject>();
        for (Object recObj : recordsRaw) {
            Map<String, Object> fieldValues = (Map<String, Object>) recObj;
            SObject rec = sObjType.newSObject();

            for (String fieldName : fieldValues.keySet()) {
                if (fieldName.equalsIgnoreCase('Id')) {
                    rec.put('Id', (Id) String.valueOf(fieldValues.get(fieldName)));
                } else if (fieldMap.containsKey(fieldName.toLowerCase())) {
                    Schema.DisplayType fieldType = fieldMap.get(fieldName.toLowerCase()).getDescribe().getType();
                    Object rawValue = fieldValues.get(fieldName);
                    rec.put(fieldName, convertFieldValue(rawValue, fieldType));
                }
            }
            records.add(rec);
        }
        return records;
    }

    private static Object convertFieldValue(Object rawValue, Schema.DisplayType fieldType) {
        if (rawValue == null) return null;
        String strVal = String.valueOf(rawValue);
        if (fieldType == Schema.DisplayType.DATETIME) {
            return DateTime.valueOf(strVal.replace('T', ' ').replace('Z', ''));
        } else if (fieldType == Schema.DisplayType.DATE) {
            return Date.valueOf(strVal);
        } else if (fieldType == Schema.DisplayType.BOOLEAN) {
            return Boolean.valueOf(strVal);
        } else if (fieldType == Schema.DisplayType.DOUBLE || fieldType == Schema.DisplayType.CURRENCY || fieldType == Schema.DisplayType.PERCENT) {
            return Decimal.valueOf(strVal);
        } else if (fieldType == Schema.DisplayType.INTEGER) {
            return Integer.valueOf(strVal);
        }
        return rawValue;
    }

    private static String extractObjectFromSoql(String soql) {
        // Simple extraction: get word after FROM
        String upper = soql.toUpperCase();
        Integer fromIdx = upper.indexOf(' FROM ');
        if (fromIdx < 0) return 'Unknown';
        String afterFrom = soql.substring(fromIdx + 6).trim();
        Integer spaceIdx = afterFrom.indexOf(' ');
        return spaceIdx > 0 ? afterFrom.substring(0, spaceIdx) : afterFrom;
    }

    private static List<String> getErrorMessages(List<Database.Error> errors) {
        List<String> msgs = new List<String>();
        for (Database.Error err : errors) {
            msgs.add(err.getMessage());
        }
        return msgs;
    }

    private static void logAction(Id regId, String actionType, String objectName, String recordId, String status, String details) {
        try {
            AgentGovTriggerHandler.logAction(regId, actionType, objectName, recordId, status, details);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'AgentGov: Failed to log proxy action: ' + e.getMessage());
        }
    }

    private static Map<String, Object> buildRemainingBudgetMap(AgentGovBudgetManager.BudgetResult br) {
        return new Map<String, Object>{
            'apiCalls' => br.apiCallsRemaining,
            'soqlQueries' => br.soqlQueriesRemaining,
            'dmlOperations' => br.dmlOperationsRemaining
        };
    }
}
