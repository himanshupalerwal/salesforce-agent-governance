/**
 * @description Tests for the REST response envelope, including the internal-error path that
 *              logs the exception and hides it from the caller.
 */
@IsTest
private class AgentGovRestResponderTest {
    private static Map<String, Object> body() {
        return (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
    }

    @IsTest
    static void successEnvelopeCarriesPayloadAndCorrelationId() {
        RestRequest request = new RestRequest();
        request.addHeader(AgentGovConstants.REST_HEADER_CORRELATION_ID, 'abc-123');
        RestContext.response = new RestResponse();

        String correlationId = AgentGovRestResponder.correlationId(request);
        AgentGovRestResponder.success(
            RestContext.response,
            201,
            new Map<String, Object>{ 'value' => 42 },
            correlationId
        );

        Assert.areEqual('abc-123', correlationId);
        Assert.areEqual(201, RestContext.response.statusCode);
        Assert.areEqual(true, body().get('success'));
        Assert.areEqual(42, body().get('value'));
        Assert.areEqual('abc-123', body().get('correlationId'));
        Assert.areEqual('application/json', RestContext.response.headers.get('Content-Type'));
    }

    @IsTest
    static void correlationIdIsGeneratedWhenAbsent() {
        String generated = AgentGovRestResponder.correlationId(new RestRequest());
        Assert.areEqual(36, generated.length(), 'A UUID is generated');
        Assert.areNotEqual(generated, AgentGovRestResponder.correlationId(new RestRequest()));
        Assert.areEqual(36, AgentGovRestResponder.correlationId(null).length());
    }

    @IsTest
    static void errorEnvelopeMapsCodeToStatus() {
        RestContext.response = new RestResponse();

        AgentGovRestResponder.error(
            RestContext.response,
            new AgentGovException(AgentGovException.ErrorCode.RECORD_LOCKED, 'held'),
            'cid'
        );

        Assert.areEqual(409, RestContext.response.statusCode);
        Assert.areEqual(false, body().get('success'));
        Assert.areEqual('RECORD_LOCKED', body().get('errorCode'));
        Assert.areEqual('held', body().get('message'));
        Assert.isNotNull(body().get('timestamp'));
    }

    @IsTest
    static void notFoundUsesAgentNotFoundCode() {
        RestContext.response = new RestResponse();

        AgentGovRestResponder.notFound(RestContext.response, '/nope', 'cid');

        Assert.areEqual(404, RestContext.response.statusCode);
        Assert.isTrue(String.valueOf(body().get('message')).endsWith('/nope'));
    }

    @IsTest
    static void internalErrorIsLoggedNotEchoed() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'Responder Agent',
            'Agentforce',
            true
        );
        RestContext.response = new RestResponse();

        AgentGovRestResponder.internalError(
            RestContext.response,
            new SurpriseException('secret detail'),
            'cid-500',
            reg.Id
        );

        Assert.areEqual(500, RestContext.response.statusCode);
        Assert.areEqual('INTERNAL_ERROR', body().get('errorCode'));
        Assert.areEqual(AgentGovConstants.ERR_INTERNAL, body().get('message'));
        Assert.isFalse(
            RestContext.response.responseBody.toString().contains('secret detail'),
            'Exception text never reaches the caller'
        );
        AgentGov_Action_Log__c entry = [
            SELECT Action_Type__c, Status__c, Details__c, Error_Message__c
            FROM AgentGov_Action_Log__c
            WHERE Agent_Registration__c = :reg.Id
        ];
        Assert.areEqual(AgentGovConstants.ACTION_SYSTEM, entry.Action_Type__c);
        Assert.areEqual(AgentGovConstants.ACTION_FAILURE, entry.Status__c);
        Assert.isTrue(entry.Details__c.contains('cid-500'), 'The correlation id links the log row to the response');
        Assert.isTrue(entry.Error_Message__c.contains('secret detail'), 'The diagnostic is kept for administrators');
    }

    @IsTest
    static void remainingBudgetShapesResult() {
        AgentGovBudgetManager.BudgetResult budget = new AgentGovBudgetManager.BudgetResult();
        budget.apiCallsRemaining = 1;
        budget.soqlQueriesRemaining = 2;
        budget.dmlOperationsRemaining = 3;

        Map<String, Object> shaped = AgentGovRestResponder.remainingBudget(budget);

        Assert.areEqual(1, shaped.get('apiCalls'));
        Assert.areEqual(2, shaped.get('soqlQueries'));
        Assert.areEqual(3, shaped.get('dmlOperations'));
    }

    private class SurpriseException extends Exception {
    }
}
