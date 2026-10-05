/**
 * @description Per-request context for the audit trail: the correlation id that ties a request
 *              to its audit rows, and when the request started, so each row can record how long
 *              the call had taken when it was written.
 *
 *              Entry points start a request before they write anything. The REST and proxy
 *              endpoints call begin() with the caller's X-Correlation-Id header, and the console
 *              calls it with none, so an id is generated. The invocable actions call
 *              ensureBegun() with the first Correlation ID input in their batch, so every
 *              AgentGov action in one transaction uses the id of the first one that ran.
 *
 *              Rows written outside a request, by a scheduled job or by Apex that started none,
 *              carry no correlation id and no request duration. Action rows persisted from
 *              AgentGov_Action_Event__e keep the values captured when the event was built;
 *              alert rows, and System rows written inside an event trigger, carry neither.
 *
 *              Touches no data. Security posture: inherited sharing.
 */
public inherited sharing class AgentGovRequestContext {
    private static final Integer MAX_CORRELATION_ID_LENGTH = 255;
    private static String correlationId;
    private static Long startedAt;

    /**
     * @description Starts a request.
     * @param requestCorrelationId The caller's correlation id, or blank to generate one
     */
    public static void begin(String requestCorrelationId) {
        correlationId = String.isBlank(requestCorrelationId)
            ? UUID.randomUUID().toString()
            : requestCorrelationId.left(MAX_CORRELATION_ID_LENGTH);
        startedAt = System.currentTimeMillis();
    }

    /**
     * @description Starts a request unless one is already in progress in this transaction.
     *              Used by invocable actions, which can run inside a request that has begun.
     * @param requestCorrelationId The caller's correlation id, or blank to generate one
     */
    public static void ensureBegun(String requestCorrelationId) {
        if (startedAt == null) {
            begin(requestCorrelationId);
        }
    }

    /**
     * @description Returns the current request's correlation id.
     * @return The correlation id, or null when no request was begun, as in a scheduled job
     */
    public static String getCorrelationId() {
        return correlationId;
    }

    /**
     * @description Returns the milliseconds since the request began.
     * @return Elapsed milliseconds, or null when no request was begun
     */
    public static Long elapsedMs() {
        return startedAt == null ? null : System.currentTimeMillis() - startedAt;
    }

    /** @description Forgets the current request. For tests that simulate several requests. */
    @TestVisible
    private static void reset() {
        correlationId = null;
        startedAt = null;
    }
}
