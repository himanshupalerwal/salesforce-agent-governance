/**
 * @description Actions an administrator takes from the AgentGov console: reset circuit
 *              breakers, activate and deactivate agents, end sessions, credit budgets, rotate
 *              API keys, and schedule the background jobs.
 *
 *              Security posture: with sharing. Every method first checks a custom permission on
 *              the server: AgentGov_Operate_Agents, or AgentGov_Manage_Keys for key rotation. It
 *              then reads the target records WITH USER_MODE, so a user can only act on agents
 *              they can see, and only then calls the service classes, which write in system
 *              mode. Every change is recorded as an Admin row in the action log in the same
 *              transaction, all or nothing: there is never a change without its audit row, or
 *              an audit row for a change that did not happen. AgentGovDashboardController stays
 *              read-only and cacheable.
 *
 *              Operational failures are returned as outcomes rather than thrown, because a
 *              thrown exception would also roll back the System row that records the cause.
 */
public with sharing class AgentGovAdminController {
    /** @description Outcome of an action for one record. */
    public class ActionOutcome {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public Boolean success;
        @AuraEnabled
        public String message;
    }

    /** @description A newly issued API key. The key is returned once and never stored. */
    public class IssuedKey {
        @AuraEnabled
        public Boolean success;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public String apiKey;
        @AuraEnabled
        public String apiKeyPrefix;
        @AuraEnabled
        public DateTime rotatedAt;
    }

    /** @description What the console's setup checklist shows. */
    public class SetupStatus {
        @AuraEnabled
        public Boolean governanceEnabled;
        @AuraEnabled
        public Boolean adminEmailConfigured;
        @AuraEnabled
        public Boolean notifyAgentOwners;
        @AuraEnabled
        public Integer sessionIdleMinutes;
        @AuraEnabled
        public List<AgentGovJobScheduler.JobStatus> jobs;
        @AuraEnabled
        public List<String> policyProblems;
    }

    /**
     * @description Closes the circuit breakers of the selected agents and reactivates the
     *              agents that their breakers had blocked.
     * @param registrationIds Agents to reset, at most 200
     * @return One outcome per requested agent
     */
    @AuraEnabled
    public static List<ActionOutcome> resetBreakers(List<Id> registrationIds) {
        requireOperate();
        Map<Id, AgentGov_Registration__c> targets = visibleRegistrations(registrationIds);
        AgentGovRequestContext.begin(null);
        Savepoint savepoint = Database.setSavepoint();
        try {
            AgentGovCircuitBreaker.resetBreakers(targets.keySet());
            audit(
                describeEach(
                    targets.values(),
                    'Circuit breaker reset from the console. It was ',
                    'Circuit_Breaker_State__c'
                )
            );
            return outcomes(registrationIds, targets.keySet(), 'Circuit breaker closed.');
        } catch (Exception e) {
            return failed(savepoint, registrationIds, 'The circuit breakers could not be reset.', e);
        }
    }

    /**
     * @description Activates the selected agents, subject to the org's concurrent-agent limit.
     * @param registrationIds Agents to activate, at most 200
     * @return One outcome per requested agent
     */
    @AuraEnabled
    public static List<ActionOutcome> activateAgents(List<Id> registrationIds) {
        requireOperate();
        Map<Id, AgentGov_Registration__c> targets = visibleRegistrations(registrationIds);
        AgentGovRequestContext.begin(null);
        Savepoint savepoint = Database.setSavepoint();
        try {
            AgentGovRegistryService.activateAgents(targets.keySet());
            audit(describeEach(targets.values(), 'Agent activated from the console. Its status was ', 'Status__c'));
            return outcomes(registrationIds, targets.keySet(), 'Agent activated.');
        } catch (Exception e) {
            return failed(savepoint, registrationIds, 'The agents could not be activated.', e);
        }
    }

    /**
     * @description Deactivates the selected agents and ends their sessions. A deactivated
     *              agent is refused on every entry point until it is activated again.
     * @param registrationIds Agents to deactivate, at most 200
     * @return One outcome per requested agent
     */
    @AuraEnabled
    public static List<ActionOutcome> deactivateAgents(List<Id> registrationIds) {
        requireOperate();
        Map<Id, AgentGov_Registration__c> targets = visibleRegistrations(registrationIds);
        AgentGovRequestContext.begin(null);
        Savepoint savepoint = Database.setSavepoint();
        try {
            AgentGovRegistryService.deactivateAgents(targets.keySet());
            audit(describeEach(targets.values(), 'Agent deactivated from the console. Its status was ', 'Status__c'));
            return outcomes(registrationIds, targets.keySet(), 'Agent deactivated.');
        } catch (Exception e) {
            return failed(savepoint, registrationIds, 'The agents could not be deactivated.', e);
        }
    }

    /**
     * @description Ends the selected sessions. The agents keep working; their next governed
     *              call opens a new session.
     * @param sessionIds Sessions to end, at most 200
     * @return One outcome per requested session
     */
    @AuraEnabled
    public static List<ActionOutcome> endSessions(List<Id> sessionIds) {
        requireOperate();
        Set<Id> requested = requireSelection(sessionIds);
        Map<Id, AgentGov_Session__c> targets;
        try {
            targets = new Map<Id, AgentGov_Session__c>(
                [SELECT Id, Agent_Registration__c FROM AgentGov_Session__c WHERE Id IN :requested WITH USER_MODE]
            );
        } catch (Exception e) {
            throw auraError(AgentGovConstants.ERR_NO_RECORD_ACCESS);
        }
        AgentGovRequestContext.begin(null);
        Savepoint savepoint = Database.setSavepoint();
        try {
            List<AgentGov_Session__c> ended = AgentGovRegistryService.terminateSessions(targets.keySet());
            List<AgentGov_Action_Log__c> rows = new List<AgentGov_Action_Log__c>();
            for (AgentGov_Session__c session : ended) {
                rows.add(
                    adminRow(
                        targets.get(session.Id).Agent_Registration__c,
                        'Session ' + session.Id + ' ended from the console.'
                    )
                );
            }
            AgentGovDml.insertRecords(rows, true);
            return outcomes(sessionIds, targets.keySet(), 'Session ended.');
        } catch (Exception e) {
            return failed(savepoint, sessionIds, 'The sessions could not be ended.', e);
        }
    }

    /**
     * @description Credits usage back to an agent's budget for today, for example after an
     *              incident was resolved. The budget status is re-evaluated from the corrected
     *              usage, so a Blocked budget can return to a lower status.
     * @param registrationId The agent
     * @param limitType API_Calls, SOQL_Queries, or DML_Operations
     * @param amount Units to credit back, at least 1
     * @return The outcome
     */
    @AuraEnabled
    public static ActionOutcome creditBudget(Id registrationId, String limitType, Integer amount) {
        requireOperate();
        if (amount == null || amount < 1) {
            throw auraError(AgentGovConstants.ERR_INVALID_CREDIT);
        }
        if (!AgentGovConstants.VALID_LIMIT_TYPES.contains(limitType)) {
            throw auraError(AgentGovConstants.ERR_INVALID_LIMIT_TYPE + limitType);
        }
        List<Id> requested = new List<Id>{ registrationId };
        Map<Id, AgentGov_Registration__c> targets = visibleRegistrations(requested);
        AgentGovRequestContext.begin(null);
        Savepoint savepoint = Database.setSavepoint();
        try {
            if (targets.isEmpty()) {
                return outcomes(requested, targets.keySet(), null)[0];
            }
            AgentGovBudgetManager.BudgetResult budget = AgentGovBudgetManager.creditBudget(
                registrationId,
                limitType,
                amount
            );
            String limitLabel = AgentGovConstants.LIMIT_LABELS.containsKey(limitType)
                ? AgentGovConstants.LIMIT_LABELS.get(limitType)
                : limitType;
            String summary = 'Credited ' + amount + ' ' + limitLabel + ' to today\'s budget.';
            AgentGovDml.insertRecords(
                new List<AgentGov_Action_Log__c>{
                    adminRow(
                        registrationId,
                        summary + ' Status is now ' + budget.budgetStatus + '. Done from the console.'
                    )
                },
                true
            );
            return outcomes(requested, targets.keySet(), summary)[0];
        } catch (Exception e) {
            return failed(savepoint, requested, 'The budget could not be credited.', e)[0];
        }
    }

    /**
     * @description Issues a replacement API key for an agent. The previous key stops working
     *              at once. The new key is returned this one time; only its hash is stored, and
     *              the audit row records only its prefix.
     * @param registrationId The agent
     * @return The new key, or the reason it could not be issued
     */
    @AuraEnabled
    public static IssuedKey rotateApiKey(Id registrationId) {
        if (!FeatureManagement.checkPermission(AgentGovConstants.CUSTOM_PERMISSION_MANAGE_KEYS)) {
            throw auraError(AgentGovConstants.ERR_MANAGE_KEYS_PERMISSION);
        }
        List<Id> requested = new List<Id>{ registrationId };
        Map<Id, AgentGov_Registration__c> targets = visibleRegistrations(requested);
        AgentGovRequestContext.begin(null);
        IssuedKey issued = new IssuedKey();
        Savepoint savepoint = Database.setSavepoint();
        try {
            if (targets.isEmpty()) {
                issued.success = false;
                issued.message = outcomes(requested, targets.keySet(), null)[0].message;
                return issued;
            }
            String apiKey = AgentGovRegistryService.issueApiKey(registrationId);
            String prefix = AgentGovRestAuth.keyPrefix(apiKey);
            AgentGovDml.insertRecords(
                new List<AgentGov_Action_Log__c>{
                    adminRow(registrationId, 'API key replaced from the console. New key prefix: ' + prefix + '.')
                },
                true
            );
            issued.success = true;
            issued.apiKey = apiKey;
            issued.apiKeyPrefix = prefix;
            issued.rotatedAt = DateTime.now();
            return issued;
        } catch (Exception e) {
            issued.success = false;
            issued.message = failed(savepoint, requested, 'The API key could not be replaced.', e)[0].message;
            return issued;
        }
    }

    /**
     * @description Schedules the three background jobs, replacing any AgentGov jobs that are
     *              already scheduled.
     * @return The outcome
     */
    @AuraEnabled
    public static ActionOutcome scheduleJobs() {
        requireOperate();
        AgentGovRequestContext.begin(null);
        Savepoint savepoint = Database.setSavepoint();
        List<Id> none = new List<Id>{ null };
        try {
            AgentGovJobScheduler.scheduleAll();
            AgentGovDml.insertRecords(
                new List<AgentGov_Action_Log__c>{ adminRow(null, 'Background jobs scheduled from the console.') },
                true
            );
            return outcomes(none, new Set<Id>{ null }, 'The three background jobs are scheduled.')[0];
        } catch (Exception e) {
            return failed(savepoint, none, 'The background jobs could not be scheduled.', e)[0];
        }
    }

    /**
     * @description Reports the setup state the console's checklist shows: whether governance
     *              is on, whether alerts reach anyone, the jobs and their next runs, and any
     *              policy misconfiguration.
     * @return The setup state
     */
    @AuraEnabled(cacheable=true)
    public static SetupStatus getSetupStatus() {
        requireOperate();
        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        SetupStatus status = new SetupStatus();
        status.governanceEnabled = AgentGovSelector.isFrameworkEnabled();
        status.adminEmailConfigured = String.isNotBlank(settings.Admin_Notification_Email__c);
        status.notifyAgentOwners = settings.Notify_Agent_Owners__c == true;
        status.sessionIdleMinutes = settings.Session_Idle_Minutes__c == null
            ? AgentGovConstants.DEFAULT_SESSION_IDLE_MINUTES
            : settings.Session_Idle_Minutes__c.intValue();
        status.jobs = AgentGovJobScheduler.getJobStatus();
        status.policyProblems = AgentGovPolicyEngine.validatePolicies();
        return status;
    }

    // --- Private helpers ---

    private static void requireOperate() {
        if (!FeatureManagement.checkPermission(AgentGovConstants.CUSTOM_PERMISSION_OPERATE_AGENTS)) {
            throw auraError(AgentGovConstants.ERR_OPERATE_PERMISSION);
        }
    }

    private static Set<Id> requireSelection(List<Id> recordIds) {
        Set<Id> requested = new Set<Id>();
        if (recordIds != null) {
            for (Id recordId : recordIds) {
                if (recordId != null) {
                    requested.add(recordId);
                }
            }
        }
        if (requested.isEmpty()) {
            throw auraError(AgentGovConstants.ERR_NOTHING_SELECTED);
        }
        if (requested.size() > AgentGovConstants.MAX_ADMIN_BATCH) {
            throw auraError(
                String.format(
                    AgentGovConstants.ERR_ADMIN_BATCH_TOO_LARGE,
                    new List<String>{ String.valueOf(AgentGovConstants.MAX_ADMIN_BATCH) }
                )
            );
        }
        return requested;
    }

    // Read in user mode, so a person can only act on agents they are allowed to see.
    private static Map<Id, AgentGov_Registration__c> visibleRegistrations(List<Id> registrationIds) {
        Set<Id> requested = requireSelection(registrationIds);
        try {
            return new Map<Id, AgentGov_Registration__c>(
                [
                    SELECT Id, Agent_Name__c, Status__c, Circuit_Breaker_State__c
                    FROM AgentGov_Registration__c
                    WHERE Id IN :requested
                    WITH USER_MODE
                ]
            );
        } catch (Exception e) {
            throw auraError(AgentGovConstants.ERR_NO_RECORD_ACCESS);
        }
    }

    private static Map<Id, String> describeEach(List<AgentGov_Registration__c> targets, String prefix, String field) {
        Map<Id, String> details = new Map<Id, String>();
        for (AgentGov_Registration__c target : targets) {
            details.put(target.Id, prefix + target.get(field) + '.');
        }
        return details;
    }

    // All or nothing: a change must not stand without its audit row.
    private static void audit(Map<Id, String> detailsByAgent) {
        List<AgentGov_Action_Log__c> rows = new List<AgentGov_Action_Log__c>();
        for (Id agentId : detailsByAgent.keySet()) {
            rows.add(adminRow(agentId, detailsByAgent.get(agentId)));
        }
        AgentGovDml.insertRecords(rows, true);
    }

    // The person who acted is the row's CreatedById, so no name is copied into the text.
    private static AgentGov_Action_Log__c adminRow(Id agentId, String details) {
        return new AgentGov_Action_Log__c(
            Agent_Registration__c = agentId,
            Action_Type__c = AgentGovConstants.ACTION_ADMIN,
            Status__c = AgentGovConstants.ACTION_SUCCESS,
            Timestamp__c = DateTime.now(),
            Correlation_Id__c = AgentGovRequestContext.getCorrelationId(),
            Details__c = details
        );
    }

    private static List<ActionOutcome> outcomes(List<Id> requested, Set<Id> done, String message) {
        List<ActionOutcome> results = new List<ActionOutcome>();
        for (Id recordId : requested) {
            ActionOutcome outcome = new ActionOutcome();
            outcome.recordId = recordId;
            outcome.success = done.contains(recordId);
            outcome.message = outcome.success ? message : AgentGovConstants.ERR_NO_RECORD_ACCESS;
            results.add(outcome);
        }
        return results;
    }

    private static List<ActionOutcome> failed(
        Savepoint savepoint,
        List<Id> requested,
        String summary,
        Exception cause
    ) {
        Database.rollback(savepoint);
        String shown;
        if (cause instanceof AgentGovException) {
            // Framework messages are written for people and are shown as they are.
            shown = cause.getMessage();
        } else {
            // Anything else is unexpected: the detail goes to the action log, not the screen.
            AgentGovTriggerHandler.recordFrameworkEvent(
                null,
                AgentGovConstants.ACTION_FAILURE,
                summary,
                cause.getTypeName() + ': ' + cause.getMessage() + '\n' + cause.getStackTraceString()
            );
            shown = summary + ' The details are in the AgentGov action log.';
        }
        List<ActionOutcome> results = new List<ActionOutcome>();
        for (Id recordId : requested) {
            ActionOutcome outcome = new ActionOutcome();
            outcome.recordId = recordId;
            outcome.success = false;
            outcome.message = shown;
            results.add(outcome);
        }
        return results;
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        // AuraHandledException hides its constructor message from clients unless it is set explicitly.
        error.setMessage(message);
        return error;
    }
}
