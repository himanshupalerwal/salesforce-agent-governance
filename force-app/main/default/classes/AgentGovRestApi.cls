/**
 * @description REST API endpoints for external AI agents to interact with AgentGov.
 *              Enables MCP servers and external systems to register, authorize actions,
 *              check budgets, and monitor agent health.
 * @author Himanshu Palerwal
 */
@RestResource(urlMapping='/agentgov/*')
global with sharing class AgentGovRestApi {

    /**
     * @description POST handler for /register and /authorize endpoints.
     */
    @HttpPost
    global static void doPost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        try {
            String path = req.requestURI.substringAfter('/agentgov');
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

            if (path == '/register') {
                handleRegister(body, res);
            } else if (path == '/authorize') {
                handleAuthorize(body, res);
            } else {
                res.statusCode = 404;
                res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                    'error' => 'Endpoint not found: ' + path
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
                'error' => e.getMessage()
            }));
        }
    }

    /**
     * @description GET handler for /budget/{agentId} and /health/{agentId} endpoints.
     */
    @HttpGet
    global static void doGet() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        try {
            String path = req.requestURI.substringAfter('/agentgov');

            if (path.startsWith('/budget/')) {
                String agentId = path.substringAfter('/budget/');
                handleGetBudget(agentId, res);
            } else if (path.startsWith('/health/')) {
                String agentId = path.substringAfter('/health/');
                handleGetHealth(agentId, res);
            } else {
                res.statusCode = 404;
                res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                    'error' => 'Endpoint not found: ' + path
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
                'error' => e.getMessage()
            }));
        }
    }

    // --- Private handlers ---

    private static void handleRegister(Map<String, Object> body, RestResponse res) {
        String agentName = (String) body.get('agentName');
        String agentType = (String) body.get('agentType');
        String description = (String) body.get('description');
        String apiKey = (String) body.get('apiKey');
        String ownerEmail = (String) body.get('ownerEmail');

        AgentGov_Registration__c reg = AgentGovRegistryService.registerAgent(
            agentName, agentType, description, apiKey, ownerEmail
        );

        res.statusCode = 201;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'success' => true,
            'registrationId' => reg.Id,
            'registrationNumber' => reg.Name,
            'status' => reg.Status__c,
            'message' => 'Agent registered successfully. Call activateAgent to enable.'
        }));
    }

    private static void handleAuthorize(Map<String, Object> body, RestResponse res) {
        String apiKey = (String) body.get('apiKey');
        String objectName = (String) body.get('objectName');
        String operation = (String) body.get('operation');
        String recordId = (String) body.get('recordId');

        // Validate API key
        if (String.isBlank(apiKey)) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                'apiKey is required.'
            );
        }

        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationByApiKey(apiKey);
        if (reg == null) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.AGENT_NOT_FOUND,
                AgentGovConstants.ERR_AGENT_NOT_REGISTERED
            );
        }

        if (reg.Status__c != AgentGovConstants.STATUS_ACTIVE) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.AGENT_NOT_ACTIVE,
                AgentGovConstants.ERR_AGENT_NOT_ACTIVE
            );
        }

        // 1. Check circuit breaker
        if (!AgentGovCircuitBreaker.allowRequest(reg.Id)) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.CIRCUIT_BREAKER_OPEN,
                AgentGovConstants.ERR_CIRCUIT_BREAKER_OPEN
            );
        }

        // 2. Check policy
        AgentGovPolicyEngine.PolicyResult policyResult = AgentGovPolicyEngine.evaluatePolicy(
            reg.Id, objectName, operation
        );
        if (!policyResult.allowed) {
            publishActionEvent(reg, operation, objectName, recordId, AgentGovConstants.ACTION_DENIED);
            throw new AgentGovException(
                AgentGovException.ErrorCode.POLICY_VIOLATION,
                policyResult.denialReason
            );
        }

        // 3. Check and consume budget
        String limitType = getLimitTypeForOperation(operation);
        AgentGovBudgetManager.BudgetResult budgetResult = AgentGovBudgetManager.consumeBudget(
            reg.Id, limitType, 1
        );

        // 4. Check for conflicts (if record-specific)
        Map<String, Object> responseMap = new Map<String, Object>{
            'authorized' => true,
            'agentId' => reg.Id,
            'budgetStatus' => budgetResult.budgetStatus,
            'remainingBudget' => new Map<String, Object>{
                'apiCalls' => budgetResult.apiCallsRemaining,
                'soqlQueries' => budgetResult.soqlQueriesRemaining,
                'dmlOperations' => budgetResult.dmlOperationsRemaining
            }
        };

        if (String.isNotBlank(recordId) && String.isNotBlank(objectName)) {
            AgentGovConflictResolver.ConflictResult conflictResult =
                AgentGovConflictResolver.checkForConflict(reg.Id, recordId, objectName);
            if (conflictResult.hasConflict && conflictResult.winningAgentId != reg.Id) {
                publishActionEvent(reg, operation, objectName, recordId, AgentGovConstants.ACTION_DENIED);
                throw new AgentGovException(
                    AgentGovException.ErrorCode.RECORD_LOCKED,
                    conflictResult.message
                );
            }
            responseMap.put('conflict', new Map<String, Object>{
                'detected' => conflictResult.hasConflict,
                'resolution' => conflictResult.resolution
            });
        }

        // Log the action via platform event
        publishActionEvent(reg, operation, objectName, recordId, AgentGovConstants.ACTION_SUCCESS);

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(responseMap));
    }

    private static void handleGetBudget(String agentId, RestResponse res) {
        if (String.isBlank(agentId)) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_NULL_AGENT_ID);
        }

        AgentGovBudgetManager.BudgetResult budget = AgentGovBudgetManager.checkBudget((Id) agentId);

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'agentId' => agentId,
            'budgetStatus' => budget.budgetStatus,
            'allowed' => budget.allowed,
            'remaining' => new Map<String, Object>{
                'apiCalls' => budget.apiCallsRemaining,
                'soqlQueries' => budget.soqlQueriesRemaining,
                'dmlOperations' => budget.dmlOperationsRemaining
            },
            'usagePercent' => new Map<String, Object>{
                'apiCalls' => budget.apiUsagePercent,
                'soqlQueries' => budget.soqlUsagePercent,
                'dmlOperations' => budget.dmlUsagePercent
            }
        }));
    }

    private static void handleGetHealth(String agentId, RestResponse res) {
        if (String.isBlank(agentId)) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, AgentGovConstants.ERR_NULL_AGENT_ID);
        }

        AgentGov_Registration__c reg = AgentGovSelector.getRegistrationById((Id) agentId);
        if (reg == null) {
            throw new AgentGovException(AgentGovException.ErrorCode.AGENT_NOT_FOUND, AgentGovConstants.ERR_AGENT_NOT_FOUND);
        }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'agentId' => agentId,
            'agentName' => reg.Agent_Name__c,
            'status' => reg.Status__c,
            'circuitBreakerState' => reg.Circuit_Breaker_State__c,
            'failureCount' => reg.Failure_Count__c,
            'lastFailure' => reg.Last_Failure__c,
            'cooldownUntil' => reg.Cooldown_Until__c,
            'lastActive' => reg.Last_Active__c
        }));
    }

    private static String getLimitTypeForOperation(String operation) {
        if (operation == AgentGovConstants.ACTION_QUERY) {
            return AgentGovConstants.LIMIT_SOQL_QUERIES;
        } else if (operation == AgentGovConstants.ACTION_API_CALL) {
            return AgentGovConstants.LIMIT_API_CALLS;
        }
        return AgentGovConstants.LIMIT_DML_OPERATIONS;
    }

    private static void publishActionEvent(AgentGov_Registration__c reg, String operation, String objectName, String recordId, String status) {
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        if (settings.Enable_Real_Time_Events__c == false) {
            return;
        }

        AgentGov_Action_Event__e evt = new AgentGov_Action_Event__e(
            Agent_Id__c = reg.Id,
            Agent_Name__c = reg.Agent_Name__c,
            Action_Type__c = operation,
            Object_Name__c = objectName,
            Record_Id__c = recordId,
            Status__c = status,
            Timestamp__c = DateTime.now()
        );
        Database.SaveResult sr = EventBus.publish(evt);
        if (!sr.isSuccess()) {
            System.debug(LoggingLevel.ERROR, 'AgentGov: Failed to publish action event: ' + sr.getErrors());
        }
    }
}
