/**
 * @description REST endpoints for agent registration, authorization, usage reporting, and
 *              monitoring.
 *
 *              POST /register     Register an agent (no agent credential required).
 *              POST /authorize    Authorize an action and pre-charge its budget.
 *              POST /report       Report actual usage and reconcile against a pre-authorization.
 *              POST /rotate-key   Issue a replacement API key for the calling agent.
 *              GET  /budget/{id}  Read an agent's budget.
 *              GET  /health/{id}  Read an agent's status and circuit breaker state.
 *
 *              GET endpoints require the caller to be the agent in question or to hold the
 *              AgentGov_Admin_Access custom permission. See AgentGovRestAuth for the accepted
 *              credentials and AgentGovRestResponder for the response envelope.
 *
 *              Security posture: with sharing. Framework bookkeeping runs in system mode
 *              through the service classes; no customer data is touched here.
 */
@RestResource(urlMapping='/agentgov/*')
global with sharing class AgentGovRestApi {
    private static final String PATH_REGISTER = '/register';
    private static final String PATH_AUTHORIZE = '/authorize';
    private static final String PATH_REPORT = '/report';
    private static final String PATH_ROTATE_KEY = '/rotate-key';
    private static final String PATH_BUDGET = '/budget/';
    private static final String PATH_HEALTH = '/health/';

    /** @description Routes POST requests. */
    @HttpPost
    global static void doPost() {
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;
        String correlationId = AgentGovRestResponder.correlationId(request);
        AgentGov_Registration__c registration;

        try {
            String path = request.requestURI.substringAfter(AgentGovConstants.REST_BASE_PATH.removeEnd('/'));
            Map<String, Object> body = parseBody(request);
            switch on path {
                when '/register' {
                    AgentGovRestResponder.success(response, 201, handleRegister(body), correlationId);
                }
                when '/authorize' {
                    registration = admitForGovernedCall(AgentGovRestAuth.resolveRegistration(request, body));
                    AgentGovRestResponder.success(response, 200, handleAuthorize(registration, body), correlationId);
                }
                when '/report' {
                    // Reporting changes the ledger, so it is held to the same status check as
                    // /authorize. A suspended agent must not be able to alter its own budget.
                    registration = admitForGovernedCall(AgentGovRestAuth.resolveRegistration(request, body));
                    AgentGovRestResponder.success(response, 200, handleReport(registration, body), correlationId);
                }
                when '/rotate-key' {
                    // Held to the same status check as the other POST paths. Without it,
                    // deactivating an agent whose key has leaked does not contain the leak:
                    // the holder could mint a fresh working credential and lock the real
                    // owner out at the same time.
                    registration = AgentGovRestAuth.requireActive(
                        AgentGovRestAuth.resolveRegistration(request, body),
                        true
                    );
                    AgentGovRestResponder.success(response, 200, handleRotateKey(registration), correlationId);
                }
                when else {
                    AgentGovRestResponder.notFound(response, path, correlationId);
                }
            }
        } catch (AgentGovException e) {
            AgentGovRestResponder.error(response, e, correlationId);
        } catch (Exception e) {
            AgentGovRestResponder.internalError(response, e, correlationId, registration?.Id);
        }
    }

    /** @description Routes GET requests. */
    @HttpGet
    global static void doGet() {
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;
        String correlationId = AgentGovRestResponder.correlationId(request);
        AgentGov_Registration__c caller;

        try {
            String path = request.requestURI.substringAfter(AgentGovConstants.REST_BASE_PATH.removeEnd('/'));
            if (path.startsWith(PATH_BUDGET)) {
                Id targetId = parseRegistrationId(path.substringAfter(PATH_BUDGET));
                caller = authorizeRead(request, targetId);
                AgentGovRestResponder.success(response, 200, handleGetBudget(targetId), correlationId);
            } else if (path.startsWith(PATH_HEALTH)) {
                Id targetId = parseRegistrationId(path.substringAfter(PATH_HEALTH));
                caller = authorizeRead(request, targetId);
                AgentGovRestResponder.success(response, 200, handleGetHealth(targetId), correlationId);
            } else {
                AgentGovRestResponder.notFound(response, path, correlationId);
            }
        } catch (AgentGovException e) {
            AgentGovRestResponder.error(response, e, correlationId);
        } catch (Exception e) {
            AgentGovRestResponder.internalError(response, e, correlationId, caller?.Id);
        }
    }

    // --- POST handlers ---

    private static Map<String, Object> handleRegister(Map<String, Object> body) {
        String suppliedKey = (String) body.get(AgentGovConstants.REST_BODY_API_KEY);
        AgentGov_Registration__c registration = AgentGovRegistryService.registerAgent(
            (String) body.get('agentName'),
            (String) body.get('agentType'),
            (String) body.get('description'),
            suppliedKey,
            (String) body.get('ownerEmail')
        );
        Map<String, Object> payload = new Map<String, Object>{
            'registrationId' => registration.Id,
            'registrationNumber' => registration.Name,
            'status' => registration.Status__c
        };
        if (String.isBlank(suppliedKey)) {
            String apiKey = AgentGovRegistryService.issueApiKey(registration.Id);
            payload.put('apiKey', apiKey);
            payload.put('apiKeyPrefix', AgentGovRestAuth.keyPrefix(apiKey));
            payload.put(
                'message',
                'Agent registered. Store the apiKey now; only its hash is kept and it cannot be retrieved later. Activate the agent to enable it.'
            );
        } else {
            payload.put('apiKeyPrefix', AgentGovRestAuth.keyPrefix(suppliedKey));
            payload.put(
                'message',
                'Agent registered. The supplied apiKey is stored as a hash. Activate the agent to enable it.'
            );
        }
        return payload;
    }

    private static Map<String, Object> handleAuthorize(
        AgentGov_Registration__c registration,
        Map<String, Object> body
    ) {
        String objectName = (String) body.get('objectName');
        String operation = (String) body.get('operation');
        String recordId = (String) body.get('recordId');
        if (String.isBlank(operation) || !AgentGovConstants.VALID_OPERATIONS.contains(operation)) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                'operation is required and must be one of: ' +
                String.join(new List<String>(AgentGovConstants.VALID_OPERATIONS), ', ')
            );
        }
        // objectName is required. A policy names the object it governs, so a blank one matches
        // no policy at all and every object-scoped rule would be skipped, turning an omitted
        // field into a way to be authorized for an operation a deny policy forbids.
        if (String.isBlank(objectName)) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                AgentGovConstants.ERR_INVALID_OBJECT_NAME
            );
        }
        // Resolved through describe so the policy engine compares against the real API name.
        // Matching the caller's raw string let a variant the describe accepts but the policy
        // does not, such as one with surrounding whitespace, skip an object-scoped deny rule.
        objectName = AgentGovQueryBuilder.describe(objectName.trim()).getName();
        Integer amount = readCount(body, 'amount', 1);
        if (amount < 1) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, 'amount must be at least 1.');
        }

        // Is_Enabled__c is the documented emergency bypass: with governance off the breaker,
        // policy, budget and conflict checks are all skipped so an administrator can unblock a
        // migration. The action is still audited below.
        if (!AgentGovSelector.isFrameworkEnabled()) {
            logAction(registration, operation, objectName, recordId, AgentGovConstants.ACTION_SUCCESS, null);
            // The response keeps the shape of a normal authorization, so a client that reads
            // `authorized` and `remainingBudget` keeps working while the bypass is on. The
            // budget is read rather than charged, and `governanceEnabled` says why.
            AgentGovBudgetManager.BudgetResult budget = AgentGovBudgetManager.checkBudget(registration.Id);
            return new Map<String, Object>{
                'authorized' => true,
                'agentId' => registration.Id,
                'budgetStatus' => budget.budgetStatus,
                'remainingBudget' => AgentGovRestResponder.remainingBudget(budget),
                'governanceEnabled' => false
            };
        }

        if (!AgentGovCircuitBreaker.allowRequest(registration.Id)) {
            // Audited like the policy, conflict and budget denials below. This was the one
            // refusal that left no trace of the attempt.
            logAction(
                registration,
                operation,
                objectName,
                recordId,
                AgentGovConstants.ACTION_DENIED,
                AgentGovConstants.ERR_CIRCUIT_BREAKER_OPEN
            );
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
            logAction(
                registration,
                operation,
                objectName,
                recordId,
                AgentGovConstants.ACTION_DENIED,
                policy.denialReason
            );
            throw new AgentGovException(AgentGovException.ErrorCode.POLICY_VIOLATION, policy.denialReason);
        }

        // Conflict is settled before the budget is charged, matching the proxy and the
        // documented pipeline order. Charging first would bill an agent for a request that
        // another agent's lock was always going to refuse.
        AgentGovConflictResolver.ConflictResult conflict;
        if (String.isNotBlank(recordId) && String.isNotBlank(objectName)) {
            conflict = AgentGovConflictResolver.checkForConflict(registration.Id, recordId, objectName);
            if (conflict.hasConflict && conflict.winningAgentId != registration.Id) {
                logAction(
                    registration,
                    operation,
                    objectName,
                    recordId,
                    AgentGovConstants.ACTION_DENIED,
                    conflict.message
                );
                throw new AgentGovException(AgentGovException.ErrorCode.RECORD_LOCKED, conflict.message);
            }
        }

        AgentGovBudgetManager.BudgetResult budget;
        try {
            budget = AgentGovBudgetManager.consumeBudget(registration.Id, limitTypeFor(operation), amount);
        } catch (AgentGovException e) {
            logAction(registration, operation, objectName, recordId, AgentGovConstants.ACTION_DENIED, e.getMessage());
            throw e;
        }

        Map<String, Object> payload = new Map<String, Object>{
            'authorized' => true,
            'agentId' => registration.Id,
            'budgetStatus' => budget.budgetStatus,
            'remainingBudget' => AgentGovRestResponder.remainingBudget(budget)
        };
        if (conflict != null) {
            payload.put(
                'conflict',
                new Map<String, Object>{ 'detected' => conflict.hasConflict, 'resolution' => conflict.resolution }
            );
        }
        logAction(registration, operation, objectName, recordId, AgentGovConstants.ACTION_SUCCESS, null);
        return payload;
    }

    private static Map<String, Object> handleReport(AgentGov_Registration__c registration, Map<String, Object> body) {
        Object rawActual = body.get('actual');
        if (!(rawActual instanceof Map<String, Object>)) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, 'actual usage data is required.');
        }
        Map<String, Object> actual = (Map<String, Object>) rawActual;
        Map<String, Object> preAuthorized = body.get('preAuthorized') instanceof Map<String, Object>
            ? (Map<String, Object>) body.get('preAuthorized')
            : new Map<String, Object>();
        Map<String, String> jsonKeyToLimitType = new Map<String, String>{
            'apiCalls' => AgentGovConstants.LIMIT_API_CALLS,
            'soqlQueries' => AgentGovConstants.LIMIT_SOQL_QUERIES,
            'dmlOperations' => AgentGovConstants.LIMIT_DML_OPERATIONS
        };

        // Only usage beyond what was already pre-authorized is charged. Unused
        // pre-authorization is deliberately NOT credited back here: both figures come from the
        // caller in this same request and the framework keeps no record of what an agent
        // actually reserved, so honouring a credit would let any agent zero its own ledger by
        // over-stating preAuthorized or reporting negative usage. Corrections are an
        // administrative action through AgentGovBudgetManager.creditBudget.
        Map<String, Integer> consumption = new Map<String, Integer>();
        for (String jsonKey : jsonKeyToLimitType.keySet()) {
            if (actual.get(jsonKey) == null) {
                continue;
            }
            Integer actualCount = readNonNegativeCount(actual, jsonKey);
            Integer preAuthorizedCount = readNonNegativeCount(preAuthorized, jsonKey);
            Integer delta = actualCount - preAuthorizedCount;
            if (delta > 0) {
                consumption.put(jsonKeyToLimitType.get(jsonKey), delta);
            }
        }

        // Is_Enabled__c suspends enforcement everywhere, reporting included. Charging here
        // during an emergency bypass could deny the agent with BUDGET_EXCEEDED, which is the
        // outcome the switch exists to prevent.
        Boolean governed = AgentGovSelector.isFrameworkEnabled();
        AgentGovBudgetManager.BudgetResult budget;
        try {
            budget = (consumption.isEmpty() || !governed)
                ? AgentGovBudgetManager.checkBudget(registration.Id)
                : AgentGovBudgetManager.consumeBudget(registration.Id, consumption);
        } catch (AgentGovException denied) {
            // The consumption is already persisted by this point, so the report must be
            // audited before the denial propagates. Otherwise the usage that pushed the agent
            // over its limit appears in the ledger with nothing explaining where it came from.
            logAction(
                registration,
                AgentGovConstants.ACTION_REPORT,
                null,
                null,
                AgentGovConstants.ACTION_DENIED,
                denied.getMessage()
            );
            throw denied;
        }

        // An agent that authorizes over REST has no other way to tell the framework whether
        // its work succeeded, which previously left a tripped breaker with no route back to
        // CLOSED. Reporting the outcome here is what lets a HALF_OPEN probe resolve.
        if (governed && body.get('success') instanceof Boolean) {
            AgentGovCircuitBreaker.recordOutcomes(
                new Map<Id, Boolean>{ registration.Id => (Boolean) body.get('success') }
            );
        }

        logAction(
            registration,
            AgentGovConstants.ACTION_REPORT,
            null,
            null,
            AgentGovConstants.ACTION_SUCCESS,
            // Only the three recognised counters are recorded. Serializing the caller's whole
            // map wrote arbitrary attacker-chosen text into the audit object, and a report of
            // zero usage costs no budget, so it was an uncapped way to fill the ledger.
            JSON.serialize(
                new Map<String, Object>{
                    'apiCalls' => actual.get('apiCalls'),
                    'soqlQueries' => actual.get('soqlQueries'),
                    'dmlOperations' => actual.get('dmlOperations')
                }
            )
        );
        return new Map<String, Object>{
            'budgetStatus' => budget.budgetStatus,
            'remainingBudget' => AgentGovRestResponder.remainingBudget(budget),
            'circuitBreakerState' => AgentGovCircuitBreaker.getState(registration.Id)
        };
    }

    private static Map<String, Object> handleRotateKey(AgentGov_Registration__c registration) {
        String apiKey = AgentGovRegistryService.issueApiKey(registration.Id);
        return new Map<String, Object>{
            'apiKey' => apiKey,
            'apiKeyPrefix' => AgentGovRestAuth.keyPrefix(apiKey),
            'rotatedAt' => DateTime.now(),
            'message' => 'Store the new apiKey now; the previous key no longer authenticates.'
        };
    }

    // --- GET handlers ---

    private static Map<String, Object> handleGetBudget(Id registrationId) {
        AgentGovBudgetManager.BudgetResult budget = AgentGovBudgetManager.checkBudget(registrationId);
        return new Map<String, Object>{
            'agentId' => registrationId,
            'budgetStatus' => budget.budgetStatus,
            'allowed' => budget.allowed,
            'remaining' => AgentGovRestResponder.remainingBudget(budget),
            'usagePercent' => new Map<String, Object>{
                'apiCalls' => budget.apiUsagePercent,
                'soqlQueries' => budget.soqlUsagePercent,
                'dmlOperations' => budget.dmlUsagePercent
            }
        };
    }

    private static Map<String, Object> handleGetHealth(Id registrationId) {
        AgentGov_Registration__c registration = AgentGovSelector.getRegistrationById(registrationId);
        if (registration == null) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.AGENT_NOT_FOUND,
                AgentGovConstants.ERR_AGENT_NOT_FOUND
            );
        }
        return new Map<String, Object>{
            'agentId' => registrationId,
            'agentName' => registration.Agent_Name__c,
            'status' => registration.Status__c,
            'circuitBreakerState' => registration.Circuit_Breaker_State__c,
            'failureCount' => registration.Failure_Count__c,
            'lastFailure' => registration.Last_Failure__c,
            'cooldownUntil' => registration.Cooldown_Until__c,
            'lastActive' => registration.Last_Active__c
        };
    }

    // --- Helpers ---

    /**
     * Resolves the caller for a GET request. Callers without any agent credential may still
     * read when they hold the admin custom permission; everyone else must be the target agent.
     */
    private static AgentGov_Registration__c authorizeRead(RestRequest request, Id targetId) {
        AgentGov_Registration__c caller;
        try {
            caller = AgentGovRestAuth.resolveRegistration(request, null);
        } catch (AgentGovException notResolved) {
            if (!AgentGovRestAuth.hasAdminAccess()) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.ACCESS_DENIED,
                    AgentGovConstants.ERR_AUTH_REQUIRED
                );
            }
        }
        AgentGovRestAuth.requireOwnerOrAdmin(caller, targetId);
        return caller;
    }

    private static Id parseRegistrationId(String rawId) {
        try {
            Id registrationId = Id.valueOf(rawId);
            if (registrationId.getSObjectType() == AgentGov_Registration__c.SObjectType) {
                return registrationId;
            }
        } catch (Exception e) {
            // Fall through to the shared error below.
        }
        throw new AgentGovException(
            AgentGovException.ErrorCode.INVALID_INPUT,
            AgentGovConstants.ERR_INVALID_RECORD_ID + rawId
        );
    }

    private static Map<String, Object> parseBody(RestRequest request) {
        if (request.requestBody == null || String.isBlank(request.requestBody.toString())) {
            return new Map<String, Object>();
        }
        try {
            Object parsed = JSON.deserializeUntyped(request.requestBody.toString());
            if (parsed instanceof Map<String, Object>) {
                return (Map<String, Object>) parsed;
            }
        } catch (JSONException e) {
            // Fall through to the shared error below.
        }
        throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, 'Request body must be a JSON object.');
    }

    /**
     * @description Prepares a resolved agent for a governed call.
     *
     *              A breaker that has served its cooldown is reopened first, because tripping
     *              leaves the agent Blocked and a Blocked agent would otherwise be refused
     *              here before any breaker code could run, with no way back. Throttled is then
     *              admitted because that is the status a HALF_OPEN breaker carries; the
     *              breaker still decides whether this particular call is the single probe.
     * @param registration The resolved calling agent
     * @return The same registration once it is cleared to proceed
     * @throws AgentGovException AGENT_NOT_ACTIVE when the agent is genuinely not usable
     */
    private static AgentGov_Registration__c admitForGovernedCall(AgentGov_Registration__c registration) {
        // Throttled is the status a HALF_OPEN breaker carries, so it is admitted. A Blocked
        // agent whose cooldown has elapsed is admitted too, because otherwise the status check
        // would refuse it before the breaker could ever readmit it. Nothing is written here:
        // the OPEN to HALF_OPEN transition and the probe claim happen together under the row
        // lock in allowRequests, which handleAuthorize calls next.
        return AgentGovRestAuth.requireActive(registration, true, AgentGovCircuitBreaker.mayProbe(registration));
    }

    private static Integer readCount(Map<String, Object> source, String key, Integer defaultValue) {
        if (source == null || source.get(key) == null) {
            return defaultValue;
        }
        try {
            return Integer.valueOf(String.valueOf(source.get(key)));
        } catch (Exception e) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, key + ' must be an integer.');
        }
    }

    /**
     * @description Reads a usage count that must not be negative. Usage is a tally of work
     *              that happened, so a negative figure is always a malformed or hostile
     *              request rather than a correction.
     * @param source Map holding the value
     * @param key Property to read
     * @return The value, or 0 when absent
     * @throws AgentGovException INVALID_INPUT when the value is negative or not an integer
     */
    private static Integer readNonNegativeCount(Map<String, Object> source, String key) {
        Integer value = readCount(source, key, 0);
        if (value < 0) {
            throw new AgentGovException(AgentGovException.ErrorCode.INVALID_INPUT, key + ' must not be negative.');
        }
        return value;
    }

    private static String limitTypeFor(String operation) {
        if (operation == AgentGovConstants.ACTION_QUERY) {
            return AgentGovConstants.LIMIT_SOQL_QUERIES;
        }
        if (operation == AgentGovConstants.ACTION_API_CALL) {
            return AgentGovConstants.LIMIT_API_CALLS;
        }
        return AgentGovConstants.LIMIT_DML_OPERATIONS;
    }

    private static void logAction(
        AgentGov_Registration__c registration,
        String operation,
        String objectName,
        String recordId,
        String status,
        String details
    ) {
        AgentGovTriggerHandler.logActions(
            new List<AgentGov_Action_Event__e>{
                AgentGovTriggerHandler.buildEvent(
                    registration.Id,
                    registration.Agent_Name__c,
                    operation,
                    objectName,
                    recordId,
                    status,
                    details
                )
            }
        );
    }
}
