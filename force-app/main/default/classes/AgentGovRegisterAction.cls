/**
 * @description Invocable action that authorizes an agent action in one call: circuit
 *              breaker, policy, record conflicts, budget, and audit log. This is the primary
 *              entry point for Flow-based agents. When several agents in one batch name the
 *              same record, the agent with the best priority keeps it and the others are
 *              refused, whatever the order of the requests.
 *
 *              The action is bulk-safe. A Flow that submits 200 requests causes one
 *              registration query, one circuit-breaker pass, one budget consumption per
 *              agent, one event publish, and one breaker update. When several requests in a
 *              batch belong to one agent and their combined consumption exceeds its budget,
 *              every request for that agent is denied, so the outcome does not depend on
 *              the order of the batch.
 *
 *              Security posture: with sharing. Framework bookkeeping runs in system mode
 *              through the service classes.
 */
public with sharing class AgentGovRegisterAction {
    /** @description Request for one action. */
    public class Request {
        @InvocableVariable(label='Agent Registration ID' required=true)
        public Id registrationId;
        @InvocableVariable(
            label='Action Type'
            required=true
            description='Query, Create, Update, Delete, Upsert, API_Call, Flow_Trigger'
        )
        public String actionType;
        @InvocableVariable(label='Object Name' required=true)
        public String objectName;
        @InvocableVariable(label='Record ID')
        public String recordId;
        @InvocableVariable(
            label='Correlation ID'
            description='Optional. Stored on the audit rows so they can be traced, for example {!$Flow.InterviewGuid}. Flow runs batched into one transaction share the first id supplied.'
        )
        public String correlationId;
    }

    /** @description Outcome for one action. */
    public class Result {
        @InvocableVariable(label='Authorized')
        public Boolean authorized;
        @InvocableVariable(label='Budget Status')
        public String budgetStatus;
        @InvocableVariable(label='Denial Reason')
        public String denialReason;
    }

    /**
     * @description Authorizes each request and consumes budget for the ones that pass.
     * @param requests Requests in Flow order
     * @return Results in the same order
     */
    @InvocableMethod(
        label='Register Agent Action'
        description='Checks the circuit breaker, policy, and budget for an agent action and logs it'
        category='AgentGov'
    )
    public static List<Result> registerAction(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Integer i = 0; i < requests.size(); i++) {
            results.add(new Result());
        }
        if (requests.isEmpty()) {
            return results;
        }
        AgentGovRequestContext.ensureBegun(firstCorrelationId(requests));
        if (!AgentGovSelector.isFrameworkEnabled()) {
            // Enforcement is suspended, auditing is not. This is the window an administrator
            // most needs recorded, so every bypassed request still produces a log entry.
            Set<Id> bypassedIds = new Set<Id>();
            for (Request request : requests) {
                if (request.registrationId != null) {
                    bypassedIds.add(request.registrationId);
                }
            }
            Map<Id, AgentGov_Registration__c> bypassed = AgentGovSelector.getRegistrationsByIds(bypassedIds);
            List<AgentGov_Action_Event__e> bypassEvents = new List<AgentGov_Action_Event__e>();
            for (Integer i = 0; i < requests.size(); i++) {
                Result result = results[i];
                AgentGov_Registration__c registration = bypassed.get(requests[i].registrationId);
                if (registration == null) {
                    // The switch suspends governance, not identity. An Id that resolves to no
                    // registration is still refused, and the refusal still leaves a record.
                    deny(result, AgentGovConstants.ERR_AGENT_NOT_FOUND);
                    continue;
                }
                if (isDeactivated(registration)) {
                    deny(result, AgentGovConstants.ERR_AGENT_NOT_ACTIVE);
                    bypassEvents.add(
                        event(registration, requests[i], AgentGovConstants.ACTION_DENIED, result.denialReason)
                    );
                    continue;
                }
                result.authorized = true;
                result.budgetStatus = AgentGovConstants.BUDGET_BYPASSED;
                bypassEvents.add(event(registration, requests[i], AgentGovConstants.ACTION_SUCCESS, null));
            }
            AgentGovTriggerHandler.logActions(bypassEvents);
            return results;
        }

        Set<Id> registrationIds = new Set<Id>();
        for (Request request : requests) {
            if (request.registrationId != null) {
                registrationIds.add(request.registrationId);
            }
        }
        Map<Id, AgentGov_Registration__c> registrations = AgentGovSelector.getRegistrationsByIds(registrationIds);

        // An agent whose breaker is not CLOSED is being readmitted on probation. allowRequests
        // returns one decision per agent, so without this the single granted probe would be
        // reused for every request that agent has in the batch: 200 Flow records would all
        // reach a downstream the breaker had just declared unhealthy. Only the first request
        // per probing agent is admitted; the rest are refused like any other open breaker.
        Set<Id> probingAgents = new Set<Id>();
        for (AgentGov_Registration__c registration : registrations.values()) {
            if (registration.Circuit_Breaker_State__c != AgentGovConstants.CB_CLOSED) {
                probingAgents.add(registration.Id);
            }
        }
        Set<Id> admissible = new Set<Id>();
        for (AgentGov_Registration__c registration : registrations.values()) {
            if (!isDeactivated(registration)) {
                admissible.add(registration.Id);
            }
        }
        Set<Id> probeSpent = new Set<Id>();
        Map<Id, Boolean> breakerDecisions = AgentGovCircuitBreaker.allowRequests(admissible);

        List<Integer> candidates = new List<Integer>();
        List<AgentGov_Action_Event__e> events = new List<AgentGov_Action_Event__e>();

        // Conflict logs from the whole batch are written in one statement at the end.
        AgentGovConflictResolver.deferLogs();
        for (Integer i = 0; i < requests.size(); i++) {
            Request request = requests[i];
            Result result = results[i];
            AgentGov_Registration__c registration = registrations.get(request.registrationId);
            if (registration == null) {
                deny(result, AgentGovConstants.ERR_AGENT_NOT_FOUND);
                continue;
            }
            // Deactivation refuses an agent on every entry point, this one as well as REST.
            // Blocked and Throttled agents are decided by the circuit breaker below.
            if (isDeactivated(registration)) {
                deny(result, AgentGovConstants.ERR_AGENT_NOT_ACTIVE);
                events.add(event(registration, request, AgentGovConstants.ACTION_DENIED, result.denialReason));
                continue;
            }
            if (
                String.isBlank(request.actionType) || !AgentGovConstants.VALID_OPERATIONS.contains(request.actionType)
            ) {
                deny(result, AgentGovConstants.ERR_INVALID_ACTION_TYPE + request.actionType);
                // Audited like every other denial. The agent is known at this point, so an
                // unrecognised action type must leave the same trail as a policy or breaker
                // refusal rather than disappearing.
                events.add(event(registration, request, AgentGovConstants.ACTION_DENIED, result.denialReason));
                continue;
            }
            Boolean breakerAllows = breakerDecisions.get(registration.Id) == true;
            if (breakerAllows && probingAgents.contains(registration.Id)) {
                // The probe is worth exactly one request, not one per request in the batch.
                breakerAllows = probeSpent.add(registration.Id);
            }
            if (!breakerAllows) {
                deny(result, AgentGovConstants.ERR_CIRCUIT_BREAKER_OPEN);
                events.add(event(registration, request, AgentGovConstants.ACTION_DENIED, result.denialReason));
                continue;
            }
            AgentGovPolicyEngine.PolicyResult policy = AgentGovPolicyEngine.evaluatePolicy(
                registration.Id,
                request.objectName,
                request.actionType
            );
            if (!policy.allowed) {
                deny(result, policy.denialReason);
                events.add(event(registration, request, AgentGovConstants.ACTION_DENIED, result.denialReason));
                continue;
            }
            // Each agent that names a record claims it; the resolver keeps the claim of the
            // agent with the best priority.
            if (String.isNotBlank(request.recordId) && String.isNotBlank(request.objectName)) {
                AgentGovConflictResolver.checkForConflict(registration.Id, request.recordId, request.objectName);
            }
            candidates.add(i);
        }
        AgentGovConflictResolver.flushLogs();

        Map<Id, Map<String, Integer>> consumption = new Map<Id, Map<String, Integer>>();
        Map<Id, Integer> actionsByAgent = new Map<Id, Integer>();
        Set<Integer> awaitingBudget = new Set<Integer>();
        for (Integer i : candidates) {
            Request request = requests[i];
            AgentGov_Registration__c registration = registrations.get(request.registrationId);
            // Settled once every claim in the batch is known, so the outcome does not depend on
            // the order of the requests: an agent overridden later in the batch by a
            // higher-priority agent is refused here.
            Id holder = recordHolder(request);
            if (holder != null && holder != registration.Id) {
                AgentGov_Registration__c winner = registrations.get(holder);
                deny(
                    results[i],
                    AgentGovConstants.ERR_RECORD_LOCKED +
                    (winner != null ? ' It is held by ' + winner.Agent_Name__c + ', which has priority.' : '')
                );
                events.add(event(registration, request, AgentGovConstants.ACTION_DENIED, results[i].denialReason));
                continue;
            }
            String limitType = limitTypeFor(request.actionType);
            if (!consumption.containsKey(registration.Id)) {
                consumption.put(registration.Id, new Map<String, Integer>());
            }
            Map<String, Integer> agentConsumption = consumption.get(registration.Id);
            agentConsumption.put(
                limitType,
                (agentConsumption.containsKey(limitType) ? agentConsumption.get(limitType) : 0) + 1
            );
            actionsByAgent.put(
                registration.Id,
                (actionsByAgent.containsKey(registration.Id) ? actionsByAgent.get(registration.Id) : 0) + 1
            );
            awaitingBudget.add(i);
        }

        AgentGovBudgetManager.BatchOutcome outcome = AgentGovBudgetManager.consumeBudgets(consumption, actionsByAgent);
        Map<Id, Boolean> breakerOutcomes = new Map<Id, Boolean>();
        for (Integer i : awaitingBudget) {
            Request request = requests[i];
            Result result = results[i];
            AgentGov_Registration__c registration = registrations.get(request.registrationId);
            if (outcome.failures.containsKey(registration.Id)) {
                deny(result, outcome.failures.get(registration.Id).getMessage());
                events.add(event(registration, request, AgentGovConstants.ACTION_DENIED, result.denialReason));
            } else {
                result.authorized = true;
                result.budgetStatus = outcome.results.get(registration.Id).budgetStatus;
                events.add(event(registration, request, AgentGovConstants.ACTION_SUCCESS, null));
                breakerOutcomes.put(registration.Id, true);
            }
        }

        AgentGovTriggerHandler.logActions(events);
        AgentGovCircuitBreaker.recordOutcomes(breakerOutcomes);
        return results;
    }

    private static Id recordHolder(Request request) {
        if (String.isBlank(request.recordId) || String.isBlank(request.objectName)) {
            return null;
        }
        return AgentGovConflictResolver.getLockHolder(request.recordId, request.objectName);
    }

    private static String firstCorrelationId(List<Request> requests) {
        for (Request request : requests) {
            if (request != null && String.isNotBlank(request.correlationId)) {
                return request.correlationId;
            }
        }
        return null;
    }

    private static Boolean isDeactivated(AgentGov_Registration__c registration) {
        return registration.Status__c == AgentGovConstants.STATUS_INACTIVE;
    }

    private static void deny(Result result, String reason) {
        result.authorized = false;
        result.denialReason = reason;
    }

    private static AgentGov_Action_Event__e event(
        AgentGov_Registration__c registration,
        Request request,
        String status,
        String details
    ) {
        return AgentGovTriggerHandler.buildEvent(
            registration.Id,
            registration.Agent_Name__c,
            request.actionType,
            request.objectName,
            request.recordId,
            status,
            details
        );
    }

    private static String limitTypeFor(String actionType) {
        if (actionType == AgentGovConstants.ACTION_QUERY) {
            return AgentGovConstants.LIMIT_SOQL_QUERIES;
        }
        if (actionType == AgentGovConstants.ACTION_API_CALL) {
            return AgentGovConstants.LIMIT_API_CALLS;
        }
        return AgentGovConstants.LIMIT_DML_OPERATIONS;
    }
}
