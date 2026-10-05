/**
 * @description Builds the JSON envelope returned by every AgentGov REST endpoint, and reads the
 *              request values both REST resources share: the correlation id and the text
 *              properties of a JSON body.
 *
 *              Successful responses carry success=true, a correlationId, and the endpoint's
 *              payload. Error responses carry success=false, an errorCode, a message that is
 *              safe to show to the caller, the correlationId, and a timestamp. Unexpected
 *              exceptions are never echoed to the caller: the message and stack trace are
 *              written to the action log as one System row under the correlation id so an
 *              administrator can find them, and the caller receives a generic message plus
 *              that id.
 *
 *              Security posture: inherited sharing. The only write is the internal-error
 *              log entry, which goes through AgentGovDml.
 */
public inherited sharing class AgentGovRestResponder {
    private static final String KEY_SUCCESS = 'success';
    private static final String KEY_CORRELATION_ID = 'correlationId';
    private static final String KEY_ERROR_CODE = 'errorCode';
    private static final String KEY_MESSAGE = 'message';
    private static final String KEY_TIMESTAMP = 'timestamp';
    private static final String KEY_DEPRECATION = 'deprecation';
    private static final String CONTENT_TYPE_JSON = 'application/json';

    /**
     * @description Reads the caller's correlation id or generates one for this request.
     * @param request The current REST request
     * @return A correlation id to thread through logs and the response
     */
    public static String correlationId(RestRequest request) {
        if (request != null && request.headers != null) {
            for (String name : request.headers.keySet()) {
                if (
                    name.equalsIgnoreCase(AgentGovConstants.REST_HEADER_CORRELATION_ID) &&
                    String.isNotBlank(request.headers.get(name))
                ) {
                    return request.headers.get(name).left(255);
                }
            }
        }
        return UUID.randomUUID().toString();
    }

    /**
     * @description Reads an optional text property from a parsed JSON request body. A value of
     *              another JSON type is refused rather than cast, so a number or an object sent
     *              where text belongs is answered with 400 instead of failing with a 500.
     * @param body Parsed JSON body
     * @param name Property name
     * @return The text, or null when the property is absent or null
     * @throws AgentGovException INVALID_INPUT naming the property when its value is not a JSON string
     */
    public static String readString(Map<String, Object> body, String name) {
        Object value = body == null ? null : body.get(name);
        if (value == null || value instanceof String) {
            return (String) value;
        }
        throw new AgentGovException(
            AgentGovException.ErrorCode.INVALID_INPUT,
            String.format(AgentGovConstants.ERR_NOT_A_STRING, new List<String>{ name })
        );
    }

    /**
     * @description Writes a successful response.
     * @param response The REST response to populate
     * @param statusCode HTTP status, typically 200 or 201
     * @param payload Endpoint-specific properties to merge into the envelope
     * @param correlationId Correlation id for this request
     */
    public static void success(
        RestResponse response,
        Integer statusCode,
        Map<String, Object> payload,
        String correlationId
    ) {
        Map<String, Object> envelope = new Map<String, Object>{
            KEY_SUCCESS => true,
            KEY_CORRELATION_ID => correlationId
        };
        if (payload != null) {
            envelope.putAll(payload);
        }
        if (AgentGovRestAuth.wasBodyKeyUsed()) {
            envelope.put(KEY_DEPRECATION, AgentGovConstants.REST_DEPRECATION_BODY_KEY);
        }
        write(response, statusCode, envelope, correlationId);
    }

    /**
     * @description Writes a classified error response.
     * @param response The REST response to populate
     * @param error The framework exception describing what went wrong
     * @param correlationId Correlation id for this request
     */
    public static void error(RestResponse response, AgentGovException error, String correlationId) {
        // INTERNAL_ERROR carries raw platform text: status codes, validation-rule messages and
        // field API names collected by AgentGovDml.assertAllSucceeded. A REST agent holds no
        // access to AgentGov objects by design, so that detail is written to the action log
        // under the correlation id instead of being returned.
        if (error.getErrorCode() == AgentGovException.ErrorCode.INTERNAL_ERROR) {
            recordInternalError(
                'Internal error returned to a REST caller. Correlation id: ' + correlationId,
                error.getMessage(),
                correlationId,
                null
            );
            writeError(response, error, AgentGovConstants.ERR_INTERNAL, correlationId);
            return;
        }
        writeError(response, error, error.getMessage(), correlationId);
    }

    /**
     * @description Writes a 404 for an unknown path.
     * @param response The REST response to populate
     * @param path The unrecognised path
     * @param correlationId Correlation id for this request
     */
    public static void notFound(RestResponse response, String path, String correlationId) {
        error(
            response,
            new AgentGovException(
                AgentGovException.ErrorCode.AGENT_NOT_FOUND,
                AgentGovConstants.ERR_ENDPOINT_NOT_FOUND + path
            ),
            correlationId
        );
    }

    /**
     * @description Records an unexpected exception and writes a generic 500 response.
     *              The real message and stack trace are persisted to the action log as one
     *              System row under the correlation id, and are never returned to the caller.
     * @param response The REST response to populate
     * @param unexpected The exception that escaped the endpoint
     * @param correlationId Correlation id for this request
     * @param registrationId The calling agent, when it had been resolved before the failure
     */
    public static void internalError(
        RestResponse response,
        Exception unexpected,
        String correlationId,
        Id registrationId
    ) {
        recordInternalError(
            'Unhandled REST exception. correlationId=' + correlationId,
            unexpected.getTypeName() + ': ' + unexpected.getMessage() + '\n' + unexpected.getStackTraceString(),
            correlationId,
            registrationId
        );
        writeError(
            response,
            new AgentGovException(AgentGovException.ErrorCode.INTERNAL_ERROR, AgentGovConstants.ERR_INTERNAL),
            AgentGovConstants.ERR_INTERNAL,
            correlationId
        );
    }

    /**
     * @description Shapes a budget result's remaining amounts for a response payload.
     * @param budget The budget snapshot
     * @return Map with apiCalls, soqlQueries, and dmlOperations remaining
     */
    public static Map<String, Object> remainingBudget(AgentGovBudgetManager.BudgetResult budget) {
        return new Map<String, Object>{
            'apiCalls' => budget.apiCallsRemaining,
            'soqlQueries' => budget.soqlQueriesRemaining,
            'dmlOperations' => budget.dmlOperationsRemaining
        };
    }

    // --- Private helpers ---

    private static void write(
        RestResponse response,
        Integer statusCode,
        Map<String, Object> body,
        String correlationId
    ) {
        response.statusCode = statusCode;
        response.addHeader('Content-Type', CONTENT_TYPE_JSON);
        response.addHeader(AgentGovConstants.REST_HEADER_CORRELATION_ID, correlationId);
        response.responseBody = Blob.valueOf(JSON.serialize(body));
    }

    private static void writeError(
        RestResponse response,
        AgentGovException error,
        String message,
        String correlationId
    ) {
        write(
            response,
            error.getHttpStatusCode(),
            new Map<String, Object>{
                KEY_SUCCESS => false,
                KEY_ERROR_CODE => String.valueOf(error.getErrorCode()),
                KEY_MESSAGE => message,
                KEY_CORRELATION_ID => correlationId,
                KEY_TIMESTAMP => DateTime.now()
            },
            correlationId
        );
    }

    // The row carries the response's correlation id even when no request context was begun, so
    // the id a caller quotes always finds it.
    private static void recordInternalError(
        String details,
        String errorMessage,
        String correlationId,
        Id registrationId
    ) {
        AgentGov_Action_Log__c entry = AgentGovTriggerHandler.buildFrameworkEvent(
            registrationId,
            AgentGovConstants.ACTION_FAILURE,
            details,
            errorMessage
        );
        entry.Correlation_Id__c = correlationId;
        AgentGovTriggerHandler.recordFrameworkEvents(new List<AgentGov_Action_Log__c>{ entry });
    }
}
