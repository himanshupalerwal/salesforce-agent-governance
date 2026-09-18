/**
 * @description Writes the framework's audit trail and delivers alerts.
 *
 *              Actions are published as AgentGov_Action_Event__e platform events so the
 *              governed transaction pays only for a publish; the event trigger persists the
 *              AgentGov_Action_Log__c rows afterwards. When event publishing is disabled in
 *              settings, or the event bus rejects a publish, the rows are inserted directly
 *              so the trail stays complete. A log row that the database rejects (for example
 *              an action type that is not in the picklist) is re-inserted as a System entry
 *              carrying the original values, so no action is lost to bad input.
 *
 *              Security posture: inherited sharing. All writes go through AgentGovDml.
 *              Platform-event triggers run in system mode by platform rule.
 */
public inherited sharing class AgentGovTriggerHandler {
    /**
     * @description Most alerts listed individually in one notification email. A plain text
     *              body is capped at 32,000 characters and an event batch can be far larger,
     *              so the remainder is summarised rather than enumerated.
     */
    @TestVisible
    private static final Integer MAX_ALERTS_IN_EMAIL = 100;

    /**
     * @description Hard ceiling on the plain text body, below the platform's 32,000-character
     *              limit. The line cap alone is not enough: an agent name can be 255
     *              characters, so the listed alerts can still overrun it.
     */
    private static final Integer MAX_EMAIL_BODY_CHARACTERS = 30000;

    /**
     * @description Records one agent action.
     * @param registrationId The acting agent
     * @param actionType One of the AgentGovConstants.ACTION_* values
     * @param objectName Object acted upon
     * @param recordId Record acted upon
     * @param status One of the AgentGovConstants.ACTION_*_STATUS values (Success, Failure, Denied, Throttled)
     * @param details Free-form details
     */
    public static void logAction(
        Id registrationId,
        String actionType,
        String objectName,
        String recordId,
        String status,
        String details
    ) {
        AgentGov_Registration__c registration = AgentGovSelector.getRegistrationById(registrationId);
        logActions(
            new List<AgentGov_Action_Event__e>{
                buildEvent(
                    registrationId,
                    registration != null ? registration.Agent_Name__c : AgentGovConstants.UNKNOWN_AGENT_NAME,
                    actionType,
                    objectName,
                    recordId,
                    status,
                    details
                )
            }
        );
    }

    /**
     * @description Builds an action event without publishing it, for bulk callers.
     */
    public static AgentGov_Action_Event__e buildEvent(
        Id registrationId,
        String agentName,
        String actionType,
        String objectName,
        String recordId,
        String status,
        String details
    ) {
        return new AgentGov_Action_Event__e(
            Agent_Id__c = registrationId,
            Agent_Name__c = agentName,
            Action_Type__c = actionType,
            Object_Name__c = objectName,
            Record_Id__c = recordId,
            Status__c = status,
            Timestamp__c = DateTime.now(),
            Details__c = details
        );
    }

    /**
     * @description Records many agent actions with one publish. Falls back to direct inserts
     *              when events are disabled or a publish is rejected.
     * @param events Action events to record
     */
    public static void logActions(List<AgentGov_Action_Event__e> events) {
        // Is_Enabled__c suspends enforcement, never the audit trail. An agent acting while
        // governance is off is exactly the activity an administrator needs a record of, so
        // this deliberately does not consult AgentGovSelector.isFrameworkEnabled().
        if (events == null || events.isEmpty()) {
            return;
        }
        if (!AgentGovSelector.isRealTimeEventsEnabled()) {
            insertLogs(toLogs(events));
            return;
        }

        // Publishing runs as the caller, and the user an agent runs as is deliberately not
        // granted publish access: on a platform event, Create cannot be granted without Read,
        // and Read is subscribe access, which would let one agent watch every other agent's
        // activity. A refused publish therefore falls back to writing the rows directly in
        // system mode, so the audit trail is complete either way.
        List<Database.SaveResult> results;
        try {
            results = AgentGovDml.publishEvents(events);
        } catch (Exception publishRefused) {
            insertLogs(toLogs(events));
            return;
        }

        List<AgentGov_Action_Event__e> rejected = new List<AgentGov_Action_Event__e>();
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                rejected.add(events[i]);
            }
        }
        if (!rejected.isEmpty()) {
            insertLogs(toLogs(rejected));
        }
    }

    /**
     * @description Publishes alert events. Rejected alerts are recorded as System log entries.
     * @param alerts Alerts to publish
     */
    public static void publishAlerts(List<AgentGov_Alert__e> alerts) {
        if (!AgentGovSelector.isRealTimeEventsEnabled() || alerts == null || alerts.isEmpty()) {
            return;
        }
        // Same reasoning as logActions: the agent user cannot publish, so a refusal is
        // recorded rather than allowed to abort the governed transaction.
        List<Database.SaveResult> results;
        try {
            results = AgentGovDml.publishEvents(alerts);
        } catch (Exception publishRefused) {
            // The user an agent runs as cannot publish, so the alert trigger will never fire
            // and would never send the notification. Deliver it directly instead, otherwise a
            // budget or breaker alert raised on a REST call reaches nobody.
            recordFrameworkEvent(
                null,
                AgentGovConstants.ACTION_FAILURE,
                'Alerts could not be published by the calling user; delivering ' +
                    alerts.size() +
                    ' alert(s) directly.',
                null
            );
            handleAlerts(alerts);
            return;
        }
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                recordFrameworkEvent(
                    toRegistrationId(alerts[i].Agent_Id__c),
                    AgentGovConstants.ACTION_FAILURE,
                    'Alert could not be published: ' + alerts[i].Alert_Type__c + ' / ' + alerts[i].Limit_Type__c,
                    AgentGovDml.describeErrors(results[i].getErrors())
                );
            }
        }
    }

    /**
     * @description Persists action events as log rows. Called by AgentGovActionEventTrigger.
     * @param events Delivered events
     */
    public static void handleActionEvents(List<AgentGov_Action_Event__e> events) {
        insertLogs(toLogs(events));
    }

    /**
     * @description Emails alerts to the configured administrator address. Called by
     *              AgentGovAlertTrigger. One email is sent per delivered batch.
     * @param alerts Delivered alerts
     */
    public static void handleAlerts(List<AgentGov_Alert__e> alerts) {
        String recipient = AgentGovSelector.getSettings().Admin_Notification_Email__c;
        if (String.isBlank(recipient) || alerts == null || alerts.isEmpty()) {
            return;
        }
        if (Limits.getEmailInvocations() >= Limits.getLimitEmailInvocations()) {
            recordFrameworkEvent(
                null,
                AgentGovConstants.ACTION_FAILURE,
                'Alert email skipped: the transaction email limit was reached.',
                null
            );
            return;
        }

        // A platform-event trigger can deliver a large batch, and a plain text body is capped
        // at 32,000 characters. Listing every alert would push a big batch past that and the
        // send would fail, losing the notification entirely. The count in the subject stays
        // accurate and the full detail is in the action log.
        List<String> lines = new List<String>();
        Integer listed = Math.min(alerts.size(), MAX_ALERTS_IN_EMAIL);
        for (Integer i = 0; i < listed; i++) {
            AgentGov_Alert__e alert = alerts[i];
            lines.add(
                alert.Alert_Type__c +
                    ' alert for agent ' +
                    alert.Agent_Name__c +
                    ': ' +
                    alert.Limit_Type__c +
                    ' at ' +
                    alert.Usage_Percentage__c +
                    '% (' +
                    alert.Current_Usage__c +
                    ' of ' +
                    alert.Budget_Allocated__c +
                    ') at ' +
                    alert.Timestamp__c
            );
        }
        if (alerts.size() > listed) {
            lines.add('');
            lines.add('and ' + (alerts.size() - listed) + ' more. See the AgentGov Action Log for the complete set.');
        }
        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setToAddresses(new List<String>{ recipient });
        message.setSubject('AgentGov: ' + alerts.size() + ' agent alert' + (alerts.size() == 1 ? '' : 's'));
        // Bounded by characters as well as by count: an agent name can run to 255, so even the
        // capped number of lines can exceed the plain text limit and fail the send outright.
        message.setPlainTextBody(String.join(lines, '\n').abbreviate(MAX_EMAIL_BODY_CHARACTERS));
        message.setSaveAsActivity(false);

        try {
            for (
                Messaging.SendEmailResult result : Messaging.sendEmail(
                    new List<Messaging.SingleEmailMessage>{ message },
                    false
                )
            ) {
                if (!result.isSuccess()) {
                    List<String> errors = new List<String>();
                    for (Messaging.SendEmailError error : result.getErrors()) {
                        errors.add(error.getStatusCode() + ': ' + error.getMessage());
                    }
                    recordFrameworkEvent(
                        null,
                        AgentGovConstants.ACTION_FAILURE,
                        'Alert email could not be sent.',
                        String.join(errors, '; ')
                    );
                }
            }
        } catch (EmailException e) {
            recordFrameworkEvent(
                null,
                AgentGovConstants.ACTION_FAILURE,
                'Alert email could not be sent.',
                e.getMessage()
            );
        }
    }

    /**
     * @description Sets the unique per-agent-per-day key on budget rows before they are saved,
     *              so the key holds for rows created by any path, not only by the framework.
     *              Called by AgentGovBudgetTrigger.
     * @param budgets Budget rows about to be inserted or updated
     */
    public static void populateBudgetKeys(List<AgentGov_Budget__c> budgets) {
        for (AgentGov_Budget__c budget : budgets) {
            if (budget.Agent_Registration__c != null && budget.Budget_Date__c != null) {
                budget.Budget_Key__c = AgentGovBudgetManager.buildBudgetKey(
                    budget.Agent_Registration__c,
                    budget.Budget_Date__c
                );
            }
        }
    }

    /**
     * @description Records an audit entry about the framework itself: purge summaries,
     *              delivery failures, unhandled REST errors. Best effort by design, because
     *              it is the last resort when another write has already failed.
     * @param registrationId The agent involved, or null
     * @param status Success or Failure
     * @param details What happened
     * @param errorMessage Diagnostic detail, or null
     */
    public static void recordFrameworkEvents(List<AgentGov_Action_Log__c> entries) {
        if (entries == null || entries.isEmpty()) {
            return;
        }
        AgentGovDml.insertRecords(entries, false);
    }

    /**
     * @description Builds a framework log row without writing it, so a caller reporting many
     *              failures can insert them in one statement instead of one per failure.
     * @param registrationId The agent the note concerns, or null
     * @param status One of the AgentGovConstants.ACTION_* statuses
     * @param details Free-form details
     * @param errorMessage Underlying error text, if any
     * @return The unsaved log row
     */
    public static AgentGov_Action_Log__c buildFrameworkEvent(
        Id registrationId,
        String status,
        String details,
        String errorMessage
    ) {
        return new AgentGov_Action_Log__c(
            Agent_Registration__c = registrationId,
            Action_Type__c = AgentGovConstants.ACTION_SYSTEM,
            Status__c = status,
            Timestamp__c = DateTime.now(),
            Details__c = details == null ? null : details.left(131072),
            Error_Message__c = errorMessage == null ? null : errorMessage.left(32768)
        );
    }

    public static void recordFrameworkEvent(Id registrationId, String status, String details, String errorMessage) {
        AgentGov_Action_Log__c entry = new AgentGov_Action_Log__c(
            Agent_Registration__c = registrationId,
            Action_Type__c = AgentGovConstants.ACTION_SYSTEM,
            Status__c = status,
            Timestamp__c = DateTime.now(),
            Details__c = details == null ? null : details.left(131072),
            Error_Message__c = errorMessage == null ? null : errorMessage.left(32768)
        );
        AgentGovDml.insertRecords(new List<SObject>{ entry }, false);
    }

    // --- Private helpers ---

    private static List<AgentGov_Action_Log__c> toLogs(List<AgentGov_Action_Event__e> events) {
        List<AgentGov_Action_Log__c> logs = new List<AgentGov_Action_Log__c>();
        for (AgentGov_Action_Event__e event : events) {
            AgentGov_Action_Log__c entry = new AgentGov_Action_Log__c(
                Agent_Registration__c = toRegistrationId(event.Agent_Id__c),
                Action_Type__c = event.Action_Type__c,
                Object_Name__c = event.Object_Name__c,
                Record_Id__c = event.Record_Id__c,
                Status__c = event.Status__c,
                Timestamp__c = event.Timestamp__c != null ? event.Timestamp__c : DateTime.now(),
                Details__c = event.Details__c
            );
            if (String.isNotBlank(event.Agent_Id__c) && entry.Agent_Registration__c == null) {
                entry.Details__c =
                    (entry.Details__c != null ? entry.Details__c + '\n' : '') +
                    'Unrecognised agent Id: ' +
                    event.Agent_Id__c;
            }
            logs.add(entry);
        }
        return logs;
    }

    private static Id toRegistrationId(String rawId) {
        if (String.isBlank(rawId)) {
            return null;
        }
        try {
            Id candidate = Id.valueOf(rawId);
            return candidate.getSObjectType() == AgentGov_Registration__c.SObjectType ? candidate : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static void insertLogs(List<AgentGov_Action_Log__c> logs) {
        if (logs.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = AgentGovDml.insertRecords(logs, false);
        List<AgentGov_Action_Log__c> replacements = new List<AgentGov_Action_Log__c>();
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                replacements.add(sanitizedCopy(logs[i], results[i].getErrors()));
            }
        }
        if (replacements.isEmpty()) {
            return;
        }
        // A replacement row uses only values the framework controls. If it still fails the
        // problem is systemic, and the exception makes it visible in the platform-event
        // subscription status and Apex job logs rather than dropping the audit entry.
        AgentGovDml.assertAllSucceeded(AgentGovDml.insertRecords(replacements, false), 'Action log');
    }

    // Builds a replacement row out of values the framework fully controls. Every field the
    // caller supplied, including the agent lookup, is moved into the details text: the
    // lookup may point at a registration that no longer exists, which is itself a reason
    // the original insert was rejected.
    private static AgentGov_Action_Log__c sanitizedCopy(AgentGov_Action_Log__c original, List<Database.Error> errors) {
        String originalValues =
            'Original agent: ' +
            original.Agent_Registration__c +
            '; action type: ' +
            original.Action_Type__c +
            '; status: ' +
            original.Status__c +
            '; object: ' +
            original.Object_Name__c +
            '; record: ' +
            original.Record_Id__c +
            (original.Details__c != null ? '\n' + original.Details__c : '');
        return new AgentGov_Action_Log__c(
            Action_Type__c = AgentGovConstants.ACTION_SYSTEM,
            Status__c = AgentGovConstants.ACTION_FAILURE,
            Timestamp__c = original.Timestamp__c,
            Details__c = originalValues.left(131072),
            Error_Message__c = ('Log entry rejected: ' + AgentGovDml.describeErrors(errors)).left(32768)
        );
    }
}
