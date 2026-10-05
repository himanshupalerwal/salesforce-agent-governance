/**
 * @description Tests for the AgentGov REST endpoints: registration with generated or
 *              supplied keys, authorization, reporting, key rotation, guarded reads, and the
 *              refusal of malformed input.
 */
@IsTest
private class AgentGovRestApiTest {
    private static final String KEY = 'rest-test-key-001';

    /** @description A caller-supplied key long enough that its stored prefix does not reveal it. */
    private static final String CHOSEN_KEY = 'agk_rest_api_test_chosen_key_001';

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistrationWithApiKey(
            'REST Test Agent',
            'MCP_External',
            KEY
        );
        AgentGovTestDataFactory.createBudget(reg.Id, true);
    }

    private static AgentGov_Registration__c primaryAgent() {
        return [
            SELECT Id, API_Key_Hash__c, API_Key__c
            FROM AgentGov_Registration__c
            WHERE Agent_Name__c = 'REST Test Agent'
        ];
    }

    private static Map<String, Object> post(String path, Map<String, Object> body, String headerKey) {
        RestRequest request = new RestRequest();
        request.requestURI = '/services/apexrest/agentgov' + path;
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf(body == null ? '{}' : JSON.serialize(body));
        if (headerKey != null) {
            request.addHeader(AgentGovConstants.REST_HEADER_API_KEY, headerKey);
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();
        AgentGovRestApi.doPost();
        return (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
    }

    private static Map<String, Object> get(String path, String headerKey) {
        RestRequest request = new RestRequest();
        request.requestURI = '/services/apexrest/agentgov' + path;
        request.httpMethod = 'GET';
        if (headerKey != null) {
            request.addHeader(AgentGovConstants.REST_HEADER_API_KEY, headerKey);
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();
        AgentGovRestApi.doGet();
        return (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
    }

    @IsTest
    static void refusalsWhileTheBreakerIsOpenAreAudited() {
        AgentGov_Registration__c agent = primaryAgent();
        update new AgentGov_Registration__c(
            Id = agent.Id,
            Status__c = AgentGovConstants.STATUS_BLOCKED,
            Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN,
            Cooldown_Until__c = DateTime.now().addMinutes(30)
        );

        Test.startTest();
        Map<String, Object> result = post('/authorize', authorizeBody(AgentGovConstants.ACTION_QUERY), KEY);
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(403, RestContext.response.statusCode, JSON.serialize(result));
        AgentGov_Action_Log__c denied = [
            SELECT Status__c, Action_Type__c, Correlation_Id__c, Error_Message__c
            FROM AgentGov_Action_Log__c
            WHERE Agent_Registration__c = :agent.Id
        ];
        Assert.areEqual(AgentGovConstants.ACTION_DENIED, denied.Status__c);
        Assert.areEqual(AgentGovConstants.ACTION_QUERY, denied.Action_Type__c);
        Assert.areEqual(result.get('correlationId'), denied.Correlation_Id__c, 'The row traces back to the response');
        Assert.isNotNull(denied.Error_Message__c, 'The reason is recorded');
    }

    @IsTest
    static void anAuthorizedCallReportsItsSession() {
        Test.startTest();
        Map<String, Object> result = post('/authorize', authorizeBody(AgentGovConstants.ACTION_QUERY), KEY);
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual(
            [SELECT Id FROM AgentGov_Session__c WHERE Agent_Registration__c = :primaryAgent().Id].Id,
            (Id) result.get('sessionId')
        );
    }

    private static Map<String, Object> authorizeBody(String operation) {
        return new Map<String, Object>{
            'objectName' => 'Account',
            'operation' => operation,
            'recordId' => '001000000000001AAA'
        };
    }

    @IsTest
    static void registerIssuesKeyOnceAndStoresOnlyHash() {
        Test.startTest();
        Map<String, Object> result = post(
            '/register',
            new Map<String, Object>{
                'agentName' => 'New REST Agent',
                'agentType' => 'MCP_External',
                'ownerEmail' => 'owner@example.com'
            },
            null
        );
        Test.stopTest();

        Assert.areEqual(201, RestContext.response.statusCode, JSON.serialize(result));
        String apiKey = (String) result.get('apiKey');
        Assert.isTrue(
            apiKey.startsWith(AgentGovConstants.API_KEY_PREFIX),
            'Generated keys carry the recognisable prefix'
        );
        AgentGov_Registration__c created = [
            SELECT API_Key__c, API_Key_Hash__c, API_Key_Prefix__c, Status__c
            FROM AgentGov_Registration__c
            WHERE Id = :(Id) result.get('registrationId')
        ];
        Assert.isNull(created.API_Key__c, 'The plaintext key is never stored');
        Assert.areEqual(AgentGovRestAuth.hashKey(apiKey), created.API_Key_Hash__c);
        Assert.areEqual(AgentGovRestAuth.keyPrefix(apiKey), created.API_Key_Prefix__c);
        Assert.areEqual(AgentGovConstants.STATUS_INACTIVE, created.Status__c);
    }

    @IsTest
    static void registerWithSuppliedKeyHashesIt() {
        Map<String, Object> result = post(
            '/register',
            new Map<String, Object>{
                'agentName' => 'Keyed Agent',
                'agentType' => 'Agentforce',
                'apiKey' => CHOSEN_KEY
            },
            null
        );

        Assert.areEqual(201, RestContext.response.statusCode, JSON.serialize(result));
        Assert.isNull(result.get('apiKey'), 'A supplied key is not echoed back');
        AgentGov_Registration__c created = [
            SELECT API_Key__c, API_Key_Hash__c, API_Key_Prefix__c
            FROM AgentGov_Registration__c
            WHERE Id = :(Id) result.get('registrationId')
        ];
        Assert.isNull(created.API_Key__c);
        Assert.areEqual(AgentGovRestAuth.hashKey(CHOSEN_KEY), created.API_Key_Hash__c);
        Assert.isTrue(
            created.API_Key_Prefix__c.length() < CHOSEN_KEY.length(),
            'The dashboard-readable prefix never contains the whole key'
        );
    }

    @IsTest
    static void registerRejectsAKeyTooShortToHideBehindItsPrefix() {
        Map<String, Object> result = post(
            '/register',
            new Map<String, Object>{
                'agentName' => 'Short Key Agent',
                'agentType' => 'Agentforce',
                'apiKey' => 'my-chosen-key'
            },
            null
        );

        Assert.areEqual(400, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual('INVALID_INPUT', result.get('errorCode'));
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM AgentGov_Registration__c WHERE Agent_Name__c = 'Short Key Agent'],
            'The registration is not created when its key is refused'
        );
    }

    @IsTest
    static void registerRejectsInvalidInput() {
        post('/register', new Map<String, Object>{ 'agentName' => '', 'agentType' => 'Agentforce' }, null);
        Assert.areEqual(400, RestContext.response.statusCode);
    }

    @IsTest
    static void authorizeWithHeaderKeyConsumesBudget() {
        Map<String, Object> body = authorizeBody(AgentGovConstants.ACTION_UPDATE);
        body.put('amount', 3);

        Test.startTest();
        Map<String, Object> result = post('/authorize', body, KEY);
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual(true, result.get('authorized'));
        Assert.isNull(result.get('deprecation'), 'Header authentication is not deprecated');
        Map<String, Object> remaining = (Map<String, Object>) result.get('remainingBudget');
        Assert.areEqual(2997, remaining.get('dmlOperations'));
        Assert.areEqual(
            1,
            [
                SELECT COUNT()
                FROM AgentGov_Action_Log__c
                WHERE Agent_Registration__c = :primaryAgent().Id AND Status__c = :AgentGovConstants.ACTION_SUCCESS
            ]
        );
    }

    @IsTest
    static void authorizeWithBodyKeyIsDeprecatedButWorks() {
        Map<String, Object> body = authorizeBody(AgentGovConstants.ACTION_QUERY);
        body.put('apiKey', KEY);

        Map<String, Object> result = post('/authorize', body, null);

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual(AgentGovConstants.REST_DEPRECATION_BODY_KEY, result.get('deprecation'));
    }

    @IsTest
    static void authorizeRejectsBadCredentialsAndInput() {
        post('/authorize', authorizeBody(AgentGovConstants.ACTION_QUERY), null);
        Assert.areEqual(404, RestContext.response.statusCode, 'No credential at all');

        post('/authorize', authorizeBody(AgentGovConstants.ACTION_QUERY), 'unknown-key');
        Assert.areEqual(404, RestContext.response.statusCode, 'Unknown key');

        post('/authorize', authorizeBody('Explode'), KEY);
        Assert.areEqual(400, RestContext.response.statusCode, 'Unknown operation');

        Map<String, Object> zero = authorizeBody(AgentGovConstants.ACTION_QUERY);
        zero.put('amount', 0);
        post('/authorize', zero, KEY);
        Assert.areEqual(400, RestContext.response.statusCode, 'Amount below one');
    }

    @IsTest
    static void authorizeDeniesInactiveAgent() {
        AgentGov_Registration__c reg = primaryAgent();
        reg.Status__c = AgentGovConstants.STATUS_INACTIVE;
        update reg;

        Map<String, Object> result = post('/authorize', authorizeBody(AgentGovConstants.ACTION_QUERY), KEY);

        Assert.areEqual(403, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual('AGENT_NOT_ACTIVE', result.get('errorCode'));
    }

    @IsTest
    static void legacyPlaintextKeyIsUpgradedOnFirstUse() {
        AgentGov_Registration__c legacy = AgentGovTestDataFactory.createRegistrationWithLegacyKey(
            'Legacy Agent',
            'Agentforce',
            'legacy-key-9'
        );

        Map<String, Object> result = post('/authorize', authorizeBody(AgentGovConstants.ACTION_QUERY), 'legacy-key-9');

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        AgentGov_Registration__c upgraded = [
            SELECT API_Key__c, API_Key_Hash__c
            FROM AgentGov_Registration__c
            WHERE Id = :legacy.Id
        ];
        Assert.isNull(upgraded.API_Key__c, 'The plaintext is cleared');
        Assert.areEqual(
            AgentGovRestAuth.hashKey('legacy-key-9'),
            upgraded.API_Key_Hash__c,
            'The hash now authenticates the agent'
        );
    }

    @IsTest
    static void reportChargesOnlyUsageBeyondThePreAuthorization() {
        post(
            '/authorize',
            new Map<String, Object>{
                'objectName' => 'Account',
                'operation' => AgentGovConstants.ACTION_UPDATE,
                'amount' => 10
            },
            KEY
        );

        Map<String, Object> result = post(
            '/report',
            new Map<String, Object>{
                'actual' => new Map<String, Object>{ 'dmlOperations' => 7, 'soqlQueries' => 2 },
                'preAuthorized' => new Map<String, Object>{ 'dmlOperations' => 10 }
            },
            KEY
        );

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        AgentGov_Budget__c budget = [
            SELECT DML_Operations_Consumed__c, SOQL_Queries_Consumed__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c = :primaryAgent().Id
        ];
        // Only usage beyond the pre-authorization is charged, and unused pre-authorization is
        // never refunded. The agent reserved 10 DML operations and used 7, so the 10 already
        // charged at /authorize stand. The 2 SOQL queries were never pre-authorized, so they
        // are charged now.
        Assert.areEqual(
            10,
            budget.DML_Operations_Consumed__c,
            'Usage within the pre-authorized amount adds nothing and refunds nothing'
        );
        Assert.areEqual(2, budget.SOQL_Queries_Consumed__c, 'Usage that was not pre-authorized is consumed');
    }

    @IsTest
    static void reportRequiresActualUsage() {
        post(
            '/report',
            new Map<String, Object>{ 'preAuthorized' => new Map<String, Object>{ 'dmlOperations' => 1 } },
            KEY
        );
        Assert.areEqual(400, RestContext.response.statusCode);
    }

    @IsTest
    static void rotateKeyInvalidatesOldKey() {
        Map<String, Object> rotation = post('/rotate-key', null, KEY);
        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(rotation));
        String newKey = (String) rotation.get('apiKey');

        post('/authorize', authorizeBody(AgentGovConstants.ACTION_QUERY), KEY);
        Assert.areEqual(404, RestContext.response.statusCode, 'The old key no longer authenticates');

        post('/authorize', authorizeBody(AgentGovConstants.ACTION_QUERY), newKey);
        Assert.areEqual(200, RestContext.response.statusCode, 'The new key does');
    }

    @IsTest
    static void agentCanReadItsOwnBudgetAndHealth() {
        Id agentId = primaryAgent().Id;

        Map<String, Object> budget = get('/budget/' + agentId, KEY);
        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(budget));
        Assert.areEqual(AgentGovConstants.BUDGET_NORMAL, budget.get('budgetStatus'));

        Map<String, Object> health = get('/health/' + agentId, KEY);
        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(health));
        Assert.areEqual(AgentGovConstants.STATUS_ACTIVE, health.get('status'));
    }

    @IsTest
    static void agentCannotReadAnotherAgentWithoutAdminPermission() {
        AgentGov_Registration__c other = AgentGovTestDataFactory.createRegistration('Other Agent', 'Agentforce', true);
        User restricted = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Agent' });

        System.runAs(restricted) {
            Map<String, Object> result = get('/budget/' + other.Id, KEY);
            Assert.areEqual(403, RestContext.response.statusCode, JSON.serialize(result));
            Assert.areEqual('ACCESS_DENIED', result.get('errorCode'));

            get('/health/' + other.Id, null);
            Assert.areEqual(403, RestContext.response.statusCode, 'No credential and no admin permission');
        }
    }

    @IsTest
    static void unknownPathsReturnNotFound() {
        get('/unknown', KEY);
        Assert.areEqual(404, RestContext.response.statusCode);

        post('/unknown', null, KEY);
        Assert.areEqual(404, RestContext.response.statusCode);

        get('/budget/not-an-id', KEY);
        Assert.areEqual(400, RestContext.response.statusCode);
    }

    @IsTest
    static void responsesCarryCorrelationIdFromRequest() {
        RestRequest request = new RestRequest();
        request.requestURI = '/services/apexrest/agentgov/health/' + primaryAgent().Id;
        request.httpMethod = 'GET';
        request.addHeader(AgentGovConstants.REST_HEADER_API_KEY, KEY);
        request.addHeader(AgentGovConstants.REST_HEADER_CORRELATION_ID, 'trace-123');
        RestContext.request = request;
        RestContext.response = new RestResponse();

        AgentGovRestApi.doGet();

        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        Assert.areEqual('trace-123', result.get('correlationId'));
        Assert.areEqual('trace-123', RestContext.response.headers.get(AgentGovConstants.REST_HEADER_CORRELATION_ID));
    }

    @IsTest
    static void reportNeverCreditsBudgetBackOnTheAgentsWord() {
        AgentGov_Registration__c reg = primaryAgent();
        AgentGov_Budget__c budget = [SELECT Id FROM AgentGov_Budget__c WHERE Agent_Registration__c = :reg.Id];
        budget.API_Calls_Consumed__c = 100;
        budget.SOQL_Queries_Consumed__c = 100;
        update budget;

        // Both figures are caller-supplied and unverifiable, so under-reporting actual usage
        // against an inflated pre-authorization credits nothing back. A credit would let any
        // agent clear its own ledger.
        Map<String, Object> result = post(
            '/report',
            new Map<String, Object>{
                'actual' => new Map<String, Object>{ 'apiCalls' => 4, 'soqlQueries' => 10 },
                'preAuthorized' => new Map<String, Object>{ 'apiCalls' => 10, 'soqlQueries' => 10 }
            },
            KEY
        );

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        AgentGov_Budget__c after = [
            SELECT API_Calls_Consumed__c, SOQL_Queries_Consumed__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c = :reg.Id
        ];
        Assert.areEqual(100, after.API_Calls_Consumed__c, 'Unused pre-authorization is not credited back');
        Assert.areEqual(
            100,
            after.SOQL_Queries_Consumed__c,
            'Matching actual and pre-authorized usage changes nothing'
        );
    }

    @IsTest
    static void reportRejectsNegativeUsageInsteadOfCreditingIt() {
        AgentGov_Registration__c reg = primaryAgent();
        AgentGov_Budget__c budget = [SELECT Id FROM AgentGov_Budget__c WHERE Agent_Registration__c = :reg.Id];
        budget.API_Calls_Consumed__c = 500;
        update budget;

        Map<String, Object> result = post(
            '/report',
            new Map<String, Object>{ 'actual' => new Map<String, Object>{ 'apiCalls' => -1000000 } },
            KEY
        );

        Assert.areEqual(400, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual(
            500,
            [
                SELECT API_Calls_Consumed__c
                FROM AgentGov_Budget__c
                WHERE Agent_Registration__c = :reg.Id
            ]
            .API_Calls_Consumed__c,
            'A negative report cannot wipe consumption'
        );
    }

    @IsTest
    static void reportRejectsANegativePreAuthorization() {
        AgentGov_Registration__c reg = primaryAgent();
        AgentGov_Budget__c budget = [SELECT Id FROM AgentGov_Budget__c WHERE Agent_Registration__c = :reg.Id];
        budget.API_Calls_Consumed__c = 500;
        update budget;

        post(
            '/report',
            new Map<String, Object>{
                'actual' => new Map<String, Object>{ 'apiCalls' => 0 },
                'preAuthorized' => new Map<String, Object>{ 'apiCalls' => -50 }
            },
            KEY
        );

        Assert.areEqual(400, RestContext.response.statusCode, 'A negative pre-authorization is rejected');
        Assert.areEqual(
            500,
            [
                SELECT API_Calls_Consumed__c
                FROM AgentGov_Budget__c
                WHERE Agent_Registration__c = :reg.Id
            ]
            .API_Calls_Consumed__c,
            'Consumption is untouched by the rejected request'
        );
    }

    @IsTest
    static void aHalfOpenAgentCanProbeAndCloseItsBreakerOverRest() {
        AgentGov_Registration__c reg = primaryAgent();
        // A breaker that has served its cooldown moves to HALF_OPEN and carries Throttled
        // status. /authorize admits Throttled and /report records the probe's outcome, so a
        // tripped agent recovers over REST alone.
        AgentGov_Registration__c tripped = [
            SELECT Id, Circuit_Breaker_State__c, Status__c, Cooldown_Until__c
            FROM AgentGov_Registration__c
            WHERE Id = :reg.Id
        ];
        tripped.Circuit_Breaker_State__c = AgentGovConstants.CB_HALF_OPEN;
        tripped.Status__c = AgentGovConstants.STATUS_THROTTLED;
        update tripped;

        Test.startTest();
        Map<String, Object> authorized = post(
            '/authorize',
            new Map<String, Object>{ 'operation' => AgentGovConstants.ACTION_QUERY, 'objectName' => 'Account' },
            KEY
        );
        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(authorized));

        Map<String, Object> reported = post(
            '/report',
            new Map<String, Object>{ 'actual' => new Map<String, Object>{ 'apiCalls' => 1 }, 'success' => true },
            KEY
        );
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(reported));
        Assert.areEqual(
            AgentGovConstants.CB_CLOSED,
            reported.get('circuitBreakerState'),
            'Reporting a successful probe closes the breaker'
        );
        Assert.areEqual(
            AgentGovConstants.STATUS_ACTIVE,
            [SELECT Status__c FROM AgentGov_Registration__c WHERE Id = :reg.Id].Status__c,
            'The agent returns to Active without administrator intervention'
        );
    }

    @IsTest
    static void aBlockedAgentPastItsCooldownCanProbeOverRest() {
        AgentGov_Registration__c reg = primaryAgent();
        // This is the state trip() leaves an agent in: breaker OPEN and status Blocked. The
        // status check admits a Blocked agent whose cooldown has passed, so the call reaches
        // the breaker and becomes its probe.
        AgentGov_Registration__c tripped = [
            SELECT Id, Circuit_Breaker_State__c, Status__c, Cooldown_Until__c
            FROM AgentGov_Registration__c
            WHERE Id = :reg.Id
        ];
        tripped.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        tripped.Status__c = AgentGovConstants.STATUS_BLOCKED;
        tripped.Cooldown_Until__c = DateTime.now().addMinutes(-5);
        update tripped;

        Test.startTest();
        Map<String, Object> result = post(
            '/authorize',
            new Map<String, Object>{ 'operation' => AgentGovConstants.ACTION_QUERY, 'objectName' => 'Account' },
            KEY
        );
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual(true, result.get('authorized'), 'The call past the cooldown becomes the probe');
        Assert.areEqual(
            AgentGovConstants.CB_HALF_OPEN,
            [SELECT Circuit_Breaker_State__c FROM AgentGov_Registration__c WHERE Id = :reg.Id].Circuit_Breaker_State__c,
            'The breaker moved to HALF_OPEN without a scheduled job'
        );
    }

    @IsTest
    static void aBlockedAgentInsideItsCooldownIsStillRefused() {
        AgentGov_Registration__c reg = primaryAgent();
        AgentGov_Registration__c tripped = [
            SELECT Id, Circuit_Breaker_State__c, Status__c, Cooldown_Until__c
            FROM AgentGov_Registration__c
            WHERE Id = :reg.Id
        ];
        tripped.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        tripped.Status__c = AgentGovConstants.STATUS_BLOCKED;
        tripped.Cooldown_Until__c = DateTime.now().addHours(1);
        update tripped;

        post(
            '/authorize',
            new Map<String, Object>{ 'operation' => AgentGovConstants.ACTION_QUERY, 'objectName' => 'Account' },
            KEY
        );

        Assert.areEqual(
            403,
            RestContext.response.statusCode,
            'The breaker moves to HALF_OPEN only once the cooldown has elapsed'
        );
    }

    @IsTest
    static void theBypassResponseKeepsTheDocumentedShape() {
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();

        Map<String, Object> result = post(
            '/authorize',
            new Map<String, Object>{ 'operation' => AgentGovConstants.ACTION_QUERY, 'objectName' => 'Account' },
            KEY
        );

        // A client reading the documented keys must keep working while the bypass is on,
        // otherwise the bypass breaks the very traffic it exists to unblock.
        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual(true, result.get('authorized'), 'The documented key is authorized, not allowed');
        Assert.isNotNull(result.get('agentId'));
        Assert.isNotNull(result.get('remainingBudget'));
        Assert.areEqual(false, result.get('governanceEnabled'));
    }

    @IsTest
    static void registerReportsADuplicateKeyAsBadInputNotAnInternalError() {
        Map<String, Object> first = post(
            '/register',
            new Map<String, Object>{ 'agentName' => 'First', 'agentType' => 'Agentforce', 'apiKey' => CHOSEN_KEY },
            null
        );
        Assert.areEqual(201, RestContext.response.statusCode, JSON.serialize(first));

        Map<String, Object> second = post(
            '/register',
            new Map<String, Object>{ 'agentName' => 'Second', 'agentType' => 'Agentforce', 'apiKey' => CHOSEN_KEY },
            null
        );

        // 500 would both misreport a caller error and tell an unauthenticated caller whether
        // a given key is already registered.
        Assert.areEqual(400, RestContext.response.statusCode, JSON.serialize(second));
        Assert.areEqual('INVALID_INPUT', second.get('errorCode'));
        Assert.isFalse(
            String.valueOf(second.get('message')).containsIgnoreCase('duplicate'),
            'The message must not reveal that the key already exists'
        );
    }

    @IsTest
    static void authorizeRequiresAnObjectNameSoPoliciesCannotBeSkipped() {
        // A policy names the object it governs, so a request without objectName would match no
        // object-scoped policy and an operation a deny policy forbids would come back authorized.
        Map<String, Object> result = post(
            '/authorize',
            new Map<String, Object>{
                'operation' => AgentGovConstants.ACTION_DELETE,
                'recordId' => '001000000000001AAA'
            },
            KEY
        );

        Assert.areEqual(400, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual('INVALID_INPUT', result.get('errorCode'));
    }

    @IsTest
    static void rotateKeyIsRefusedForAnInactiveAgent() {
        AgentGov_Registration__c reg = primaryAgent();
        reg.Status__c = AgentGovConstants.STATUS_INACTIVE;
        update reg;

        Test.startTest();
        Map<String, Object> result = post('/rotate-key', null, KEY);
        Test.stopTest();

        // Deactivating an agent must contain a leaked key. If rotation still worked, the
        // holder could mint a fresh credential and lock the real owner out.
        Assert.areEqual(403, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual('AGENT_NOT_ACTIVE', result.get('errorCode'));
        Assert.areEqual(
            AgentGovRestAuth.hashKey(KEY),
            [SELECT API_Key_Hash__c FROM AgentGov_Registration__c WHERE Id = :reg.Id].API_Key_Hash__c,
            'The existing key is untouched'
        );
        assertKeyRotationRefusalAudited(reg.Id, result);
    }

    @IsTest
    static void rotateKeyIsRefusedForABlockedAgentEvenWhenItsBreakerMayProbe() {
        AgentGov_Registration__c reg = primaryAgent();
        update new AgentGov_Registration__c(
            Id = reg.Id,
            Status__c = AgentGovConstants.STATUS_BLOCKED,
            Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN,
            Cooldown_Until__c = DateTime.now().addMinutes(-5)
        );

        Test.startTest();
        Map<String, Object> result = post('/rotate-key', null, KEY);
        Test.stopTest();

        // Rotation is not a governed call, so the stricter check admits only Active and
        // Throttled agents and never consults the breaker.
        Assert.areEqual(403, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual('AGENT_NOT_ACTIVE', result.get('errorCode'));
        AgentGov_Registration__c after = [
            SELECT API_Key_Hash__c, Circuit_Breaker_State__c
            FROM AgentGov_Registration__c
            WHERE Id = :reg.Id
        ];
        Assert.areEqual(AgentGovRestAuth.hashKey(KEY), after.API_Key_Hash__c, 'The existing key is untouched');
        Assert.areEqual(AgentGovConstants.CB_OPEN, after.Circuit_Breaker_State__c, 'No probe was claimed');
        assertKeyRotationRefusalAudited(reg.Id, result);
    }

    private static void assertKeyRotationRefusalAudited(Id registrationId, Map<String, Object> result) {
        AgentGov_Action_Log__c denied = [
            SELECT Action_Type__c, Status__c, Details__c, Error_Message__c, Correlation_Id__c
            FROM AgentGov_Action_Log__c
            WHERE Agent_Registration__c = :registrationId
        ];
        Assert.areEqual(AgentGovConstants.ACTION_SYSTEM, denied.Action_Type__c);
        Assert.areEqual(AgentGovConstants.ACTION_DENIED, denied.Status__c);
        Assert.areEqual(
            String.format(
                AgentGovConstants.ERR_KEY_ROTATION_REFUSED,
                new List<String>{ AgentGovConstants.ERR_AGENT_NOT_ACTIVE }
            ),
            denied.Details__c
        );
        Assert.isNotNull(denied.Error_Message__c, 'The reason is recorded');
        Assert.areEqual(result.get('correlationId'), denied.Correlation_Id__c, 'The row traces back to the response');
    }

    @IsTest
    static void authorizeRefusesARecordIdThatIsNotASalesforceId() {
        Test.startTest();
        for (String recordId : new List<String>{ 'not-a-record-id', '001000000000001AAAX', 'x'.repeat(300) }) {
            Map<String, Object> body = authorizeBody(AgentGovConstants.ACTION_QUERY);
            body.put('recordId', recordId);
            Map<String, Object> result = post('/authorize', body, KEY);
            Assert.areEqual(400, RestContext.response.statusCode, JSON.serialize(result));
            Assert.areEqual('INVALID_INPUT', result.get('errorCode'));
            Assert.areEqual(AgentGovConstants.ERR_INVALID_RECORD_ID + recordId.left(255), result.get('message'));
        }
        Map<String, Object> fifteen = authorizeBody(AgentGovConstants.ACTION_QUERY);
        fifteen.put('recordId', '001000000000001');
        Map<String, Object> accepted = post('/authorize', fifteen, KEY);
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode, 'A 15-character Id is accepted: ' + accepted);
        Assert.areEqual(
            1,
            [SELECT SOQL_Queries_Consumed__c FROM AgentGov_Budget__c WHERE Agent_Registration__c = :primaryAgent().Id]
            .SOQL_Queries_Consumed__c,
            'Only the accepted request was charged'
        );
        AgentGov_Action_Log__c audited = [
            SELECT Status__c, Record_Id__c
            FROM AgentGov_Action_Log__c
            WHERE Agent_Registration__c = :primaryAgent().Id
        ];
        Assert.areEqual(AgentGovConstants.ACTION_SUCCESS, audited.Status__c, 'The refused requests left no row');
        Assert.areEqual('001000000000001', audited.Record_Id__c);
    }

    @IsTest
    static void aBodyValueOfTheWrongJsonTypeIsBadInputNotAnInternalError() {
        Map<String, Map<String, Object>> cases = new Map<String, Map<String, Object>>{
            'agentName' => new Map<String, Object>{ 'agentName' => 42, 'agentType' => 'Agentforce' },
            'apiKey' => new Map<String, Object>{
                'agentName' => 'Typed Agent',
                'agentType' => 'Agentforce',
                'apiKey' => 123456789
            }
        };
        for (String field : cases.keySet()) {
            Map<String, Object> result = post('/register', cases.get(field), null);
            Assert.areEqual(400, RestContext.response.statusCode, JSON.serialize(result));
            Assert.areEqual(
                String.format(AgentGovConstants.ERR_NOT_A_STRING, new List<String>{ field }),
                result.get('message')
            );
        }

        Map<String, Object> objectNotText = authorizeBody(AgentGovConstants.ACTION_QUERY);
        objectNotText.put('objectName', 42);
        Map<String, Object> operationNotText = authorizeBody(AgentGovConstants.ACTION_QUERY);
        operationNotText.put('operation', true);
        Map<String, Object> recordNotText = authorizeBody(AgentGovConstants.ACTION_QUERY);
        recordNotText.put('recordId', new Map<String, Object>{ 'id' => '001000000000001AAA' });
        Map<String, Map<String, Object>> authorizeCases = new Map<String, Map<String, Object>>{
            'objectName' => objectNotText,
            'operation' => operationNotText,
            'recordId' => recordNotText
        };
        for (String field : authorizeCases.keySet()) {
            Map<String, Object> result = post('/authorize', authorizeCases.get(field), KEY);
            Assert.areEqual(400, RestContext.response.statusCode, JSON.serialize(result));
            Assert.areEqual(
                String.format(AgentGovConstants.ERR_NOT_A_STRING, new List<String>{ field }),
                result.get('message')
            );
        }

        Assert.areEqual(0, [SELECT COUNT() FROM AgentGov_Registration__c WHERE Agent_Name__c = 'Typed Agent']);
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM AgentGov_Action_Log__c WHERE Action_Type__c = :AgentGovConstants.ACTION_SYSTEM],
            'No request failed as an internal error'
        );
    }

    @IsTest
    static void reportLogsOnlyTheRecognisedCounters() {
        String padding = 'x'.repeat(2000);

        Test.startTest();
        post(
            '/report',
            new Map<String, Object>{ 'actual' => new Map<String, Object>{ 'apiCalls' => 1, 'pad' => padding } },
            KEY
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        AgentGov_Action_Log__c entry = [
            SELECT Details__c
            FROM AgentGov_Action_Log__c
            WHERE Action_Type__c = :AgentGovConstants.ACTION_REPORT
            LIMIT 1
        ];
        // Serializing the caller's whole map would let any agent write arbitrary text into the
        // audit log, and a zero-usage report costs no budget, so nothing would cap it.
        Assert.isFalse(entry.Details__c.contains(padding), 'Unrecognised keys are not recorded');
        Assert.isTrue(entry.Details__c.contains('apiCalls'), 'The recognised counters are recorded');
    }

    @IsTest
    static void reportChargesNothingWhileGovernanceIsDisabled() {
        AgentGov_Registration__c reg = primaryAgent();
        AgentGov_Budget__c budget = [SELECT Id FROM AgentGov_Budget__c WHERE Agent_Registration__c = :reg.Id];
        budget.API_Calls_Consumed__c = 10;
        update budget;

        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();

        post('/report', new Map<String, Object>{ 'actual' => new Map<String, Object>{ 'apiCalls' => 500 } }, KEY);

        // The switch suspends enforcement everywhere, reporting included. Charging here could
        // deny the agent with BUDGET_EXCEEDED, which is the outcome the switch exists to avoid.
        Assert.areEqual(200, RestContext.response.statusCode);
        Assert.areEqual(
            10,
            [
                SELECT API_Calls_Consumed__c
                FROM AgentGov_Budget__c
                WHERE Agent_Registration__c = :reg.Id
            ]
            .API_Calls_Consumed__c,
            'No usage is charged while governance is off'
        );
    }

    @IsTest
    static void reportDoesNotMoveTheBreakerWhileGovernanceIsDisabled() {
        AgentGov_Registration__c reg = primaryAgent();
        AgentGov_Registration__c tripped = [
            SELECT Id, Circuit_Breaker_State__c, Status__c
            FROM AgentGov_Registration__c
            WHERE Id = :reg.Id
        ];
        tripped.Circuit_Breaker_State__c = AgentGovConstants.CB_HALF_OPEN;
        tripped.Status__c = AgentGovConstants.STATUS_THROTTLED;
        update tripped;

        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();

        post(
            '/report',
            new Map<String, Object>{ 'actual' => new Map<String, Object>{ 'apiCalls' => 1 }, 'success' => false },
            KEY
        );

        Assert.areEqual(
            AgentGovConstants.CB_HALF_OPEN,
            [SELECT Circuit_Breaker_State__c FROM AgentGov_Registration__c WHERE Id = :reg.Id].Circuit_Breaker_State__c,
            'A failure reported during a bypass must not trip the breaker and strand the agent'
        );
    }

    @IsTest
    static void reportRejectsNonIntegerCounts() {
        post(
            '/report',
            new Map<String, Object>{ 'actual' => new Map<String, Object>{ 'dmlOperations' => 'many' } },
            KEY
        );
        Assert.areEqual(400, RestContext.response.statusCode);
    }

    @IsTest
    static void malformedBodiesAreRejected() {
        for (String rawBody : new List<String>{ 'not json', '[1,2,3]' }) {
            RestRequest request = new RestRequest();
            request.requestURI = '/services/apexrest/agentgov/authorize';
            request.httpMethod = 'POST';
            request.requestBody = Blob.valueOf(rawBody);
            request.addHeader(AgentGovConstants.REST_HEADER_API_KEY, KEY);
            RestContext.request = request;
            RestContext.response = new RestResponse();

            AgentGovRestApi.doPost();

            Assert.areEqual(400, RestContext.response.statusCode, 'Must be rejected: ' + rawBody);
        }
    }

    @IsTest
    static void administratorCanReadAnyAgent() {
        AgentGov_Registration__c other = AgentGovTestDataFactory.createRegistration('Other Agent', 'Agentforce', true);

        // The running user is a system administrator and holds AgentGov_Admin_Access, so the
        // owner check is satisfied by the custom permission rather than by the credential.
        Map<String, Object> result = get('/health/' + other.Id, null);

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual('Other Agent', result.get('agentName'));
    }

    @IsTest
    static void healthOfAnUnknownAgentIsNotFound() {
        Id unknownId = AgentGov_Registration__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';

        Map<String, Object> result = get('/health/' + unknownId, KEY);

        Assert.areEqual(404, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual('AGENT_NOT_FOUND', result.get('errorCode'));
    }

    @IsTest
    static void authorizeChargesTheLimitTypeThatMatchesTheOperation() {
        Map<String, Object> apiCall = authorizeBody(AgentGovConstants.ACTION_API_CALL);
        apiCall.put('amount', 5);

        post('/authorize', apiCall, KEY);

        Assert.areEqual(200, RestContext.response.statusCode);
        AgentGov_Budget__c budget = [
            SELECT API_Calls_Consumed__c, SOQL_Queries_Consumed__c, DML_Operations_Consumed__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c = :primaryAgent().Id
        ];
        Assert.areEqual(5, budget.API_Calls_Consumed__c, 'API_Call charges the API budget');
        Assert.areEqual(0, budget.SOQL_Queries_Consumed__c);
        Assert.areEqual(0, budget.DML_Operations_Consumed__c);
    }

    @IsTest
    static void registerReturnsTheRegistrationNumber() {
        Map<String, Object> result = post(
            '/register',
            new Map<String, Object>{ 'agentName' => 'Numbered Agent', 'agentType' => 'Agentforce' },
            null
        );

        Assert.areEqual(201, RestContext.response.statusCode, JSON.serialize(result));
        Id registrationId = (Id) result.get('registrationId');
        AgentGov_Registration__c saved = [SELECT Name FROM AgentGov_Registration__c WHERE Id = :registrationId];
        Assert.areEqual(saved.Name, result.get('registrationNumber'), 'The response names the saved registration');
        Assert.isTrue(saved.Name.startsWith('AGT-'), 'The number is the auto-number: ' + saved.Name);
    }

    @IsTest
    static void registerReportsAMalformedOwnerEmailAsBadInput() {
        Map<String, Object> result = post(
            '/register',
            new Map<String, Object>{
                'agentName' => 'Bad Email Agent',
                'agentType' => 'Agentforce',
                'ownerEmail' => 'not-an-email'
            },
            null
        );

        Assert.areEqual(400, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual('INVALID_INPUT', result.get('errorCode'));
        Assert.isTrue(
            String.valueOf(result.get('message')).contains('Owner Email'),
            'The message names the field to correct: ' + result.get('message')
        );
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM AgentGov_Registration__c WHERE Agent_Name__c = 'Bad Email Agent'],
            'Nothing is registered'
        );
    }

    @IsTest
    static void aTrippedAgentIsAdmittedDuringTheEmergencyBypass() {
        AgentGov_Registration__c tripped = primaryAgent();
        tripped.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        tripped.Status__c = AgentGovConstants.STATUS_BLOCKED;
        tripped.Cooldown_Until__c = DateTime.now().addHours(1);
        update tripped;
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();

        Map<String, Object> result = post(
            '/authorize',
            new Map<String, Object>{ 'operation' => AgentGovConstants.ACTION_QUERY, 'objectName' => 'Account' },
            KEY
        );

        // The bypass lets work through while governance is suspended, as the Flow actions do;
        // a breaker that tripped before it was switched on must not keep the agent out.
        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual(true, result.get('authorized'));
        Assert.areEqual(false, result.get('governanceEnabled'));
        Assert.areEqual(
            AgentGovConstants.CB_OPEN,
            [SELECT Circuit_Breaker_State__c FROM AgentGov_Registration__c WHERE Id = :tripped.Id]
            .Circuit_Breaker_State__c,
            'The bypass leaves the breaker as it was'
        );
    }

    @IsTest
    static void aDeactivatedAgentIsRefusedDuringTheEmergencyBypass() {
        AgentGov_Registration__c agent = primaryAgent();
        agent.Status__c = AgentGovConstants.STATUS_INACTIVE;
        update agent;
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();

        Map<String, Object> result = post(
            '/authorize',
            new Map<String, Object>{ 'operation' => AgentGovConstants.ACTION_QUERY, 'objectName' => 'Account' },
            KEY
        );

        Assert.areEqual(403, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual('AGENT_NOT_ACTIVE', result.get('errorCode'));
    }

    @IsTest
    static void anUnexpectedFailureAfterTheChargeIsUndone() {
        AgentGovRestApi.failureAfterCharge = new SimulatedFailureException('Simulated failure after the charge.');
        authorizeOnce();
        Assert.areEqual(500, RestContext.response.statusCode, 'The failure is answered as an internal error');
        assertAuthorizationUndone('Simulated failure after the charge.');
    }

    @IsTest
    static void anInternalErrorAfterTheChargeIsUndone() {
        AgentGovRestApi.failureAfterCharge = new AgentGovException(
            AgentGovException.ErrorCode.INTERNAL_ERROR,
            'Simulated ledger failure after the charge.'
        );
        authorizeOnce();
        Assert.areEqual(500, RestContext.response.statusCode, 'The failure is answered as an internal error');
        assertAuthorizationUndone('Simulated ledger failure after the charge.');
    }

    private static void authorizeOnce() {
        Test.startTest();
        post(
            '/authorize',
            new Map<String, Object>{ 'operation' => AgentGovConstants.ACTION_QUERY, 'objectName' => 'Account' },
            KEY
        );
        Test.stopTest();
    }

    private static void assertAuthorizationUndone(String failureText) {
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM AgentGov_Budget__c WHERE SOQL_Queries_Consumed__c > 0],
            'The charge for an authorization the caller never received is undone'
        );
        List<AgentGov_Action_Log__c> failures = [
            SELECT Error_Message__c, Correlation_Id__c
            FROM AgentGov_Action_Log__c
            WHERE Action_Type__c = :AgentGovConstants.ACTION_SYSTEM AND Status__c = :AgentGovConstants.ACTION_FAILURE
        ];
        Assert.areEqual(1, failures.size(), 'One failure leaves exactly one System row: ' + JSON.serialize(failures));
        Assert.isTrue(
            String.valueOf(failures[0].Error_Message__c).contains(failureText),
            'The failure itself survives the rollback'
        );
        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        Assert.areEqual(
            response.get('correlationId'),
            failures[0].Correlation_Id__c,
            'The row is under the request id'
        );
    }

    private class SimulatedFailureException extends Exception {
    }
}
