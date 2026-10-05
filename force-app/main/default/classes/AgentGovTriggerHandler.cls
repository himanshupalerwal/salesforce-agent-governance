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
 *              Alerts are published as AgentGov_Alert__e for the alert trigger to record and
 *              email. An alert the publish does not accept, as when the running user may not
 *              publish, is recorded and emailed directly instead.
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

    /** @description Length of the Error_Message__c fields on the action log and its event. */
    private static final Integer MAX_ERROR_CHARACTERS = 32768;

    /** @description The messages handed to the last alert send, so tests can check recipients and bodies. */
    @TestVisible
    private static List<Messaging.SingleEmailMessage> sentAlertMessages = new List<Messaging.SingleEmailMessage>();

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
        logAction(registrationId, actionType, objectName, recordId, status, details, null);
    }

    /**
     * @description Records one agent action with the underlying error, when there is one.
     * @param registrationId The acting agent
     * @param actionType One of the AgentGovConstants.ACTION_* values
     * @param objectName Object acted upon
     * @param recordId Record acted upon
     * @param status Success, Failure, Denied, or Throttled
     * @param details Free-form details
     * @param errorMessage Why the action failed or was refused, or null
     */
    public static void logAction(
        Id registrationId,
        String actionType,
        String objectName,
        String recordId,
        String status,
        String details,
        String errorMessage
    ) {
        AgentGov_Registration__c registration = AgentGovSelector.getRegistrationById(registrationId);
        AgentGov_Action_Event__e event = buildEvent(
            registrationId,
            registration != null ? registration.Agent_Name__c : AgentGovConstants.UNKNOWN_AGENT_NAME,
            actionType,
            objectName,
            recordId,
            status,
            details
        );
        if (errorMessage != null) {
            event.Error_Message__c = errorMessage.left(MAX_ERROR_CHARACTERS);
        }
        logActions(new List<AgentGov_Action_Event__e>{ event });
    }

    /**
     * @description Builds an action event without publishing it, for bulk callers. The event
     *              carries the request's correlation id, the time the request had taken so
     *              far, and the session the agent's activity was recorded against, if any. A
     *              denial or failure also carries its reason as the row's error message.
     * @param registrationId The acting agent, or null
     * @param agentName The agent's name as the row should show it
     * @param actionType One of the AgentGovConstants.ACTION_* values
     * @param objectName Object acted upon
     * @param recordId Record acted upon
     * @param status Success, Failure, Denied, or Throttled
     * @param details Free-form details; for a denial or failure, its reason
     * @return The event, not yet published
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
        Boolean refused = status == AgentGovConstants.ACTION_DENIED || status == AgentGovConstants.ACTION_FAILURE;
        return new AgentGov_Action_Event__e(
            Agent_Id__c = registrationId,
            Agent_Name__c = agentName,
            Action_Type__c = actionType,
            Object_Name__c = objectName,
            Record_Id__c = recordId,
            Status__c = status,
            Timestamp__c = DateTime.now(),
            Details__c = details,
            Error_Message__c = refused && details != null ? details.left(MAX_ERROR_CHARACTERS) : null,
            Correlation_Id__c = AgentGovRequestContext.getCorrelationId(),
            Execution_Time_Ms__c = AgentGovRequestContext.elapsedMs(),
            Session_Id__c = AgentGovSessionTracker.currentSessionFor(registrationId)
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
     * @description Publishes alert events for AgentGovAlertTrigger to deliver. Nothing is
     *              published or delivered while Enable_Real_Time_Events__c is off. Alerts the
     *              publish does not accept, as when the running user may not publish, are
     *              delivered here directly through handleAlerts, and the refusal is recorded as
     *              one System entry.
     * @param alerts Alerts to publish
     */
    public static void publishAlerts(List<AgentGov_Alert__e> alerts) {
        if (!AgentGovSelector.isRealTimeEventsEnabled() || alerts == null || alerts.isEmpty()) {
            return;
        }
        // The user an agent runs as cannot publish, as logActions explains, and the platform
        // reports that refusal as failed save results rather than an exception. The alert
        // trigger never sees a refused alert, so it is delivered here instead; otherwise a
        // budget or breaker alert raised on a REST call would reach nobody.
        List<AgentGov_Alert__e> refused = new List<AgentGov_Alert__e>();
        Set<String> reasons = new Set<String>();
        try {
            List<Database.SaveResult> results = AgentGovDml.publishEvents(alerts);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    refused.add(alerts[i]);
                    reasons.add(AgentGovDml.describeErrors(results[i].getErrors()));
                }
            }
        } catch (Exception publishRefused) {
            refused = alerts;
            reasons.add(publishRefused.getTypeName() + ': ' + publishRefused.getMessage());
        }
        if (refused.isEmpty()) {
            return;
        }
        recordFrameworkEvent(
            null,
            AgentGovConstants.ACTION_FAILURE,
            'Alerts could not be published; delivering ' + refused.size() + ' alert(s) directly.',
            String.join(new List<String>(reasons), '; ')
        );
        handleAlerts(refused);
    }

    /**
     * @description Persists action events as log rows. Called by AgentGovActionEventTrigger.
     * @param events Delivered events
     */
    public static void handleActionEvents(List<AgentGov_Action_Event__e> events) {
        insertLogs(toLogs(events));
    }

    /**
     * @description Records each delivered alert in the action log, then emails the batch: to
     *              the administrator address in settings, and, when Notify_Agent_Owners__c is
     *              checked, to each affected agent's owner listing only that owner's agents.
     *              All messages go out in one send. Called by AgentGovAlertTrigger, and by
     *              publishAlerts for alerts the publish did not accept.
     * @param alerts Delivered alerts
     */
    public static void handleAlerts(List<AgentGov_Alert__e> alerts) {
        if (alerts == null || alerts.isEmpty()) {
            return;
        }
        // Recorded before any email decision, so alert history does not depend on whether
        // anyone is configured to receive email.
        recordAlertHistory(alerts);

        AgentGov_Settings__c settings = AgentGovSelector.getSettings();
        List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
        if (String.isNotBlank(settings.Admin_Notification_Email__c)) {
            messages.add(alertEmail(settings.Admin_Notification_Email__c, alerts));
        }
        if (settings.Notify_Agent_Owners__c == true) {
            messages.addAll(ownerEmails(alerts));
        }
        if (messages.isEmpty()) {
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
        sendAlertEmails(messages);
    }

    private static void recordAlertHistory(List<AgentGov_Alert__e> alerts) {
        List<AgentGov_Action_Log__c> rows = new List<AgentGov_Action_Log__c>();
        for (AgentGov_Alert__e alert : alerts) {
            rows.add(
                new AgentGov_Action_Log__c(
                    Agent_Registration__c = toRegistrationId(alert.Agent_Id__c),
                    Action_Type__c = AgentGovConstants.ACTION_ALERT,
                    Status__c = AgentGovConstants.ACTION_SUCCESS,
                    Timestamp__c = alert.Timestamp__c != null ? alert.Timestamp__c : DateTime.now(),
                    Details__c = describeAlert(alert)
                )
            );
        }
        insertLogs(rows);
    }

    // An alert row says what happened in words, led by a short label such as "Blocked:" that the
    // console shows as a pill. The agent is the row's registration and the time its Timestamp__c,
    // so neither is repeated in the text.
    private static String describeAlert(AgentGov_Alert__e alert) {
        if (alert.Limit_Type__c == AgentGovConstants.ALERT_LIMIT_CIRCUIT_BREAKER) {
            String reached = alert.Current_Usage__c == null ||
                alert.Budget_Allocated__c == null
                ? 'the failure threshold was reached.'
                : whole(alert.Current_Usage__c) +
                  ' failures reached the threshold of ' +
                  whole(alert.Budget_Allocated__c) +
                  '.';
            return AgentGovConstants.ALERT_LABEL_BREAKER_OPEN + ': ' + reached;
        }
        String label = AgentGovConstants.ALERT_LABELS.containsKey(alert.Alert_Type__c)
            ? AgentGovConstants.ALERT_LABELS.get(alert.Alert_Type__c)
            : alert.Alert_Type__c;
        String limitLabel = AgentGovConstants.LIMIT_LABELS.containsKey(alert.Limit_Type__c)
            ? AgentGovConstants.LIMIT_LABELS.get(alert.Limit_Type__c)
            : alert.Limit_Type__c;
        String text = label + ': ' + limitLabel + ' at ' + whole(alert.Usage_Percentage__c) + '% of today\'s budget';
        if (alert.Current_Usage__c != null && alert.Budget_Allocated__c != null) {
            text += ' (' + whole(alert.Current_Usage__c) + ' of ' + whole(alert.Budget_Allocated__c) + ')';
        }
        return text + '.';
    }

    // An email lists several agents' alerts, so each line names the agent and, because the
    // recipient's time zone is unknown, gives the time in GMT.
    private static String describeAlertForEmail(AgentGov_Alert__e alert) {
        String line = alert.Agent_Name__c + ' - ' + describeAlert(alert);
        return alert.Timestamp__c == null
            ? line
            : line + ' ' + alert.Timestamp__c.formatGmt('yyyy-MM-dd HH:mm') + ' GMT';
    }

    private static String whole(Decimal value) {
        return value == null ? '0' : String.valueOf(value.setScale(0, System.RoundingMode.HALF_UP));
    }

    private static Messaging.SingleEmailMessage alertEmail(String recipient, List<AgentGov_Alert__e> alerts) {
        // A platform-event trigger can deliver a large batch, and a plain text body is capped
        // at 32,000 characters. Listing every alert would push a big batch past that and the
        // send would fail, losing the notification entirely. The count in the subject stays
        // accurate and the full detail is in the action log.
        List<String> lines = new List<String>();
        Integer listed = Math.min(alerts.size(), MAX_ALERTS_IN_EMAIL);
        for (Integer i = 0; i < listed; i++) {
            lines.add(describeAlertForEmail(alerts[i]));
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
        return message;
    }

    // One message per owner, each listing only that owner's agents, so an owner never learns
    // about agents that belong to someone else.
    private static List<Messaging.SingleEmailMessage> ownerEmails(List<AgentGov_Alert__e> alerts) {
        Set<Id> agentIds = new Set<Id>();
        for (AgentGov_Alert__e alert : alerts) {
            Id agentId = toRegistrationId(alert.Agent_Id__c);
            if (agentId != null) {
                agentIds.add(agentId);
            }
        }
        Map<Id, AgentGov_Registration__c> agents = AgentGovSelector.getRegistrationsByIds(agentIds);
        Map<String, List<AgentGov_Alert__e>> byOwner = new Map<String, List<AgentGov_Alert__e>>();
        for (AgentGov_Alert__e alert : alerts) {
            AgentGov_Registration__c agent = agents.get(toRegistrationId(alert.Agent_Id__c));
            if (agent == null || String.isBlank(agent.Owner_Email__c)) {
                continue;
            }
            String owner = agent.Owner_Email__c.trim().toLowerCase();
            if (!byOwner.containsKey(owner)) {
                byOwner.put(owner, new List<AgentGov_Alert__e>());
            }
            byOwner.get(owner).add(alert);
        }
        List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
        for (String owner : byOwner.keySet()) {
            messages.add(alertEmail(owner, byOwner.get(owner)));
        }
        return messages;
    }

    private static void sendAlertEmails(List<Messaging.SingleEmailMessage> messages) {
        sentAlertMessages = messages;
        try {
            for (Messaging.SendEmailResult result : Messaging.sendEmail(messages, false)) {
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
     * @description Sets the key that allows at most one active session per agent: the agent's
     *              registration Id while the session is Active, blank once it has ended. Blank
     *              values never collide, so any number of ended sessions can exist. Called by
     *              AgentGovSessionTrigger.
     * @param sessions Session rows about to be inserted or updated
     */
    public static void populateSessionKeys(List<AgentGov_Session__c> sessions) {
        for (AgentGov_Session__c session : sessions) {
            Boolean active =
                session.Status__c == AgentGovConstants.SESSION_ACTIVE &&
                session.Agent_Registration__c != null;
            session.Active_Session_Key__c = active ? String.valueOf(session.Agent_Registration__c) : null;
        }
    }

    /**
     * @description Records audit entries about the framework itself (purge summaries,
     *              delivery failures, unhandled REST errors) in one statement. Best effort by
     *              design, because it is the last resort when another write has already failed.
     * @param entries Rows built with buildFrameworkEvent
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
            Correlation_Id__c = AgentGovRequestContext.getCorrelationId(),
            Details__c = details == null ? null : details.left(131072),
            Error_Message__c = errorMessage == null ? null : errorMessage.left(MAX_ERROR_CHARACTERS)
        );
    }

    /**
     * @description Records one audit entry about the framework itself. See recordFrameworkEvents.
     * @param registrationId The agent the note concerns, or null
     * @param status One of the AgentGovConstants.ACTION_* statuses
     * @param details What happened
     * @param errorMessage Underlying error text, if any
     */
    public static void recordFrameworkEvent(Id registrationId, String status, String details, String errorMessage) {
        AgentGovDml.insertRecords(
            new List<SObject>{ buildFrameworkEvent(registrationId, status, details, errorMessage) },
            false
        );
    }

    // --- Private helpers ---

    private static List<AgentGov_Action_Log__c> toLogs(List<AgentGov_Action_Event__e> events) {
        List<AgentGov_Action_Log__c> logs = new List<AgentGov_Action_Log__c>();
        for (AgentGov_Action_Event__e event : events) {
            AgentGov_Action_Log__c entry = new AgentGov_Action_Log__c(
                Agent_Registration__c = toRegistrationId(event.Agent_Id__c),
                Agent_Session__c = toSessionId(event.Session_Id__c),
                Action_Type__c = event.Action_Type__c,
                Object_Name__c = event.Object_Name__c,
                Record_Id__c = event.Record_Id__c,
                Status__c = event.Status__c,
                Timestamp__c = event.Timestamp__c != null ? event.Timestamp__c : DateTime.now(),
                Details__c = event.Details__c,
                Error_Message__c = event.Error_Message__c,
                Correlation_Id__c = event.Correlation_Id__c,
                Execution_Time_Ms__c = event.Execution_Time_Ms__c
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
        return toIdOf(rawId, AgentGov_Registration__c.SObjectType);
    }

    private static Id toSessionId(String rawId) {
        return toIdOf(rawId, AgentGov_Session__c.SObjectType);
    }

    private static Id toIdOf(String rawId, Schema.SObjectType expectedType) {
        if (String.isBlank(rawId)) {
            return null;
        }
        try {
            Id candidate = Id.valueOf(rawId);
            return candidate.getSObjectType() == expectedType ? candidate : null;
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
        // problem is systemic, and the exception makes it visible rather than dropping the audit
        // entry: in the event trigger it shows in the subscription status, and on the
        // direct-insert path it fails the caller's request.
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
            Correlation_Id__c = original.Correlation_Id__c,
            Details__c = originalValues.left(131072),
            Error_Message__c = ('Log entry rejected: ' + AgentGovDml.describeErrors(errors)).left(32768)
        );
    }
}
