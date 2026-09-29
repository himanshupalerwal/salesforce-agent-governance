/**
 * @description Per-request context for the audit trail: the correlation id that ties a request
 *              to its audit rows, and when the request started, so each row can record how long
 *              the call had taken when it was written.
 *
 *              Entry points call begin() first: the REST endpoints with the caller's
 *              X-Correlation-Id header, the invocable actions with the optional Correlation ID
 *              input. Rows written outside a request, by a scheduled job or an event trigger,
 *              carry neither a correlation id nor a duration.
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
