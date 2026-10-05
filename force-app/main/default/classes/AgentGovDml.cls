/**
 * @description Data-manipulation layer for the framework's own records: registrations,
 *              budgets, sessions, action logs, conflict logs, and platform events.
 *
 *              Security posture: without sharing, and every DML statement runs in
 *              AccessLevel.SYSTEM_MODE; platform events are published as the running user.
 *              The framework's ledger must be written on behalf of whoever triggered the
 *              governed action, including Agentforce Agent Users and integration users that
 *              hold no CRUD or field-level access to AgentGov objects. Since API version 67.0
 *              database operations default to user mode, so the elevation has to be explicit
 *              and is confined to this class. Anything executed on behalf of an agent against
 *              customer data (the proxy endpoints) deliberately does not use this class.
 *
 *              Every method returns the results it gets back. Callers that pass
 *              allOrNone=false receive the raw results and decide what a failure means;
 *              callers that pass allOrNone=true get a DmlException from the platform.
 */
@SuppressWarnings('PMD.ApexSharingViolations, PMD.ApexCRUDViolation')
public without sharing class AgentGovDml {
    // Errors that reject a value the caller supplied, as opposed to a fault in the org.
    private static final Set<StatusCode> REJECTED_VALUE_CODES = new Set<StatusCode>{
        StatusCode.INVALID_EMAIL_ADDRESS,
        StatusCode.STRING_TOO_LONG,
        StatusCode.NUMBER_OUTSIDE_VALID_RANGE,
        StatusCode.INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST,
        StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION
    };
    /**
     * @description Test-only switch that makes publishEvents throw, so tests can cover the
     *              fallbacks for a publish that fails outright. A user without Create on the
     *              event is refused with failed save results instead, which tests reproduce by
     *              publishing as such a user.
     */
    @TestVisible
    private static Boolean simulatePublishRefusal = false;

    /**
     * @description Inserts records in system mode.
     * @param records Records to insert
     * @param allOrNone Whether a single failure rolls back the whole statement
     * @return Save results in the same order as the input
     */
    public static List<Database.SaveResult> insertRecords(List<SObject> records, Boolean allOrNone) {
        if (records == null || records.isEmpty()) {
            return new List<Database.SaveResult>();
        }
        return Database.insert(records, allOrNone, AccessLevel.SYSTEM_MODE);
    }

    /**
     * @description Inserts a single record in system mode, failing loudly on error.
     * @param record Record to insert
     */
    public static void insertRecord(SObject record) {
        insertRecords(new List<SObject>{ record }, true);
    }

    /**
     * @description Updates records in system mode.
     * @param records Records to update
     * @param allOrNone Whether a single failure rolls back the whole statement
     * @return Save results in the same order as the input
     */
    public static List<Database.SaveResult> updateRecords(List<SObject> records, Boolean allOrNone) {
        if (records == null || records.isEmpty()) {
            return new List<Database.SaveResult>();
        }
        return Database.update(records, allOrNone, AccessLevel.SYSTEM_MODE);
    }

    /**
     * @description Updates a single record in system mode, failing loudly on error.
     * @param record Record to update
     */
    public static void updateRecord(SObject record) {
        updateRecords(new List<SObject>{ record }, true);
    }

    /**
     * @description Deletes records in system mode.
     * @param records Records to delete
     * @param allOrNone Whether a single failure rolls back the whole statement
     * @return Delete results in the same order as the input
     */
    public static List<Database.DeleteResult> deleteRecords(List<SObject> records, Boolean allOrNone) {
        if (records == null || records.isEmpty()) {
            return new List<Database.DeleteResult>();
        }
        return Database.delete(records, allOrNone, AccessLevel.SYSTEM_MODE);
    }

    /**
     * @description Publishes platform events as the running user. A user without Create on
     *              the event is refused: the save results come back failed rather than an
     *              exception being thrown, and the callers in AgentGovTriggerHandler then write
     *              the audit rows, or deliver the alerts, directly in system mode.
     * @param events Platform events to publish
     * @return Save results in the same order as the input
     */
    public static List<Database.SaveResult> publishEvents(List<SObject> events) {
        if (events == null || events.isEmpty()) {
            return new List<Database.SaveResult>();
        }
        if (Test.isRunningTest() && simulatePublishRefusal) {
            throw new System.NoAccessException();
        }
        return EventBus.publish(events);
    }

    /**
     * @description Throws an INTERNAL_ERROR exception describing the first failure, if any.
     *              Use after a partial-success statement whose failures must not be ignored.
     * @param results Save results to inspect
     * @param context Short description of what was being written, used in the message
     */
    public static void assertAllSucceeded(List<Database.SaveResult> results, String context) {
        for (Database.SaveResult result : results) {
            if (!result.isSuccess()) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.INTERNAL_ERROR,
                    context + ' failed: ' + describeErrors(result.getErrors())
                );
            }
        }
    }

    /**
     * @description Returns true when every error on a failed save is a duplicate-value
     *              violation. The budget layer uses this to recognise that another
     *              transaction created the same row first.
     * @param result A failed save result
     * @return True when the failure is purely a uniqueness collision
     */
    public static Boolean isDuplicateValueFailure(Database.SaveResult result) {
        if (result.isSuccess() || result.getErrors().isEmpty()) {
            return false;
        }
        for (Database.Error error : result.getErrors()) {
            if (error.getStatusCode() != StatusCode.DUPLICATE_VALUE) {
                return false;
            }
        }
        return true;
    }

    /**
     * @description Returns true when every error on a thrown DmlException is a duplicate-value
     *              violation. Used where an all-or-none write hits a unique index and the
     *              caller wants to report it as bad input rather than an internal failure.
     * @param failure The exception raised by an all-or-none write
     * @return True when the failure is purely a uniqueness collision
     */
    public static Boolean isDuplicateValueFailure(DmlException failure) {
        if (failure == null || failure.getNumDml() == 0) {
            return false;
        }
        for (Integer i = 0; i < failure.getNumDml(); i++) {
            if (failure.getDmlType(i) != StatusCode.DUPLICATE_VALUE) {
                return false;
            }
        }
        return true;
    }

    /**
     * @description Returns true when every error on a thrown DmlException rejects a value the
     *              caller supplied, such as a malformed email address or text too long for its
     *              field. Used to report such a failure as bad input rather than an internal one.
     * @param failure The exception raised by an all-or-none write
     * @return True when every error rejects a supplied value
     */
    public static Boolean isRejectedValueFailure(DmlException failure) {
        if (failure == null || failure.getNumDml() == 0) {
            return false;
        }
        for (Integer i = 0; i < failure.getNumDml(); i++) {
            if (!REJECTED_VALUE_CODES.contains(failure.getDmlType(i))) {
                return false;
            }
        }
        return true;
    }

    /**
     * @description Flattens a list of database errors into a single readable string.
     * @param errors Errors from a save, upsert, or delete result
     * @return Semicolon-separated messages with their status codes
     */
    public static String describeErrors(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error error : errors) {
            messages.add(error.getStatusCode() + ': ' + error.getMessage());
        }
        return String.join(messages, '; ');
    }
}
