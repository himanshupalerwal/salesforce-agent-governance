/**
 * @description Tests for the governed proxy: structured queries, injection resistance,
 *              write validation, policy enforcement, and budget accounting.
 */
@IsTest
private class AgentGovProxyApiTest {
    private static final String KEY = 'proxy-test-key-001';
    private static final String MCP_KEY = 'proxy-mcp-key-002';

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGovTestDataFactory.createRegistrationWithApiKey(
            'Proxy Test Agent',
            AgentGovConstants.AGENT_TYPE_CUSTOM_APEX,
            KEY
        );
        AgentGovTestDataFactory.createRegistrationWithApiKey(
            'Proxy MCP Agent',
            AgentGovConstants.AGENT_TYPE_MCP_EXTERNAL,
            MCP_KEY
        );
    }

    private static Map<String, Object> post(String path, Map<String, Object> body, String headerKey) {
        RestRequest request = new RestRequest();
        request.requestURI = '/services/apexrest/agentgov-proxy' + path;
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf(JSON.serialize(body));
        if (headerKey != null) {
            request.addHeader(AgentGovConstants.REST_HEADER_API_KEY, headerKey);
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();
        AgentGovProxyApi.doPost();
        return (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
    }

    private static Map<String, Object> queryBody(String objectName, List<String> fields) {
        return new Map<String, Object>{ 'objectName' => objectName, 'fields' => fields, 'limit' => 5 };
    }

    private static Map<String, Object> condition(String field, String op, Object value) {
        return new Map<String, Object>{ 'field' => field, 'op' => op, 'value' => value };
    }

    @IsTest
    static void structuredQueryReturnsRecords() {
        Map<String, Object> body = queryBody('AgentGov_Registration__c', new List<String>{ 'Id', 'Agent_Name__c' });
        body.put('where', new List<Object>{ condition('Agent_Name__c', '=', 'Proxy Test Agent') });
        body.put('orderBy', new Map<String, Object>{ 'field' => 'Agent_Name__c', 'direction' => 'desc' });

        Test.startTest();
        Map<String, Object> result = post('/query', body, KEY);
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual(true, result.get('success'));
        Assert.areEqual(1, result.get('totalSize'));
        Assert.isNotNull(result.get('correlationId'));
        Assert.isNotNull(result.get('budgetStatus'));
    }

    @IsTest
    static void rawSoqlIsRejected() {
        Map<String, Object> result = post(
            '/query',
            new Map<String, Object>{ 'query' => 'SELECT Id FROM AgentGov_Registration__c' },
            KEY
        );

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.isTrue(String.valueOf(result.get('message')).contains('Raw SOQL'), 'The error explains the migration');
    }

    @IsTest
    static void relationshipPathsAndSubqueriesCannotBeExpressed() {
        Map<String, Object> dotted = post(
            '/query',
            queryBody('AgentGov_Budget__c', new List<String>{ 'Agent_Registration__r.Agent_Name__c' }),
            KEY
        );
        Assert.areEqual(400, RestContext.response.statusCode, JSON.serialize(dotted));

        Map<String, Object> nested = post(
            '/query',
            queryBody('AgentGov_Registration__c', new List<String>{ '(SELECT Id FROM Governor_Budgets__r)' }),
            KEY
        );
        Assert.areEqual(400, RestContext.response.statusCode, JSON.serialize(nested));

        Map<String, Object> unknown = post(
            '/query',
            queryBody('AgentGov_Registration__c', new List<String>{ 'No_Such_Field__c' }),
            KEY
        );
        Assert.areEqual(400, RestContext.response.statusCode, JSON.serialize(unknown));
    }

    @IsTest
    static void injectionPayloadInValueIsBoundNotConcatenated() {
        Map<String, Object> body = queryBody('AgentGov_Registration__c', new List<String>{ 'Id' });
        body.put('where', new List<Object>{ condition('Agent_Name__c', '=', 'x\' OR Agent_Name__c != \'') });

        Map<String, Object> result = post('/query', body, KEY);

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual(0, result.get('totalSize'), 'The payload is compared literally and matches nothing');
    }

    @IsTest
    static void unsupportedOperatorIsRejected() {
        Map<String, Object> body = queryBody('AgentGov_Registration__c', new List<String>{ 'Id' });
        body.put('where', new List<Object>{ condition('Agent_Name__c', 'INCLUDES', 'x') });

        post('/query', body, KEY);

        Assert.areEqual(400, RestContext.response.statusCode);
    }

    @IsTest
    static void policyRecordCapLimitsQueryRows() {
        // More rows than the shipped MCP_External read policy allows, so the cap is what
        // decides the result size rather than the data.
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 205; i++) {
            accounts.add(new Account(Name = 'Cap test ' + i));
        }
        insert accounts;
        Map<String, Object> body = queryBody('Account', new List<String>{ 'Id' });
        body.put('limit', 5000);

        Map<String, Object> result = post('/query', body, MCP_KEY);

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual(200, result.get('totalSize'), 'The policy caps the rows returned at 200 of 205');
    }

    @IsTest
    static void aUserWithoutObjectAccessIsRefusedInTheFrameworksOwnWords() {
        User restricted = AgentGovTestDataFactory.createRestrictedUser(new List<String>());

        System.runAs(restricted) {
            Map<String, Object> result = post(
                '/create',
                new Map<String, Object>{
                    'objectName' => 'Account',
                    'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 'Forbidden Account' } }
                },
                KEY
            );

            Assert.areEqual(403, RestContext.response.statusCode, JSON.serialize(result));
            Assert.areEqual('ACCESS_DENIED', result.get('errorCode'));
            String message = String.valueOf(result.get('message'));
            Assert.isTrue(message.contains('not permitted to create Account'), message);
            Assert.isFalse(message.containsIgnoreCase('exception'), 'Platform text leaked: ' + message);
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Name = 'Forbidden Account']);
    }

    @IsTest
    static void anUnexpectedFailureUndoesTheWriteAndTheCharge() {
        AgentGovProxyApi.failureAfterWrite = new SimulatedFailureException('Simulated failure after the write.');
        createOnce();
        Assert.areEqual(500, RestContext.response.statusCode, 'The failure is answered as an internal error');
        assertCreateUndone('Simulated failure after the write');
    }

    @IsTest
    static void anInternalErrorAfterTheWriteIsUndoneToo() {
        // An INTERNAL_ERROR raised as an AgentGovException, such as a breaker update that fails
        // after the records were saved, also answers 500 and must leave nothing behind.
        AgentGovProxyApi.failureAfterWrite = new AgentGovException(
            AgentGovException.ErrorCode.INTERNAL_ERROR,
            'Simulated ledger failure after the write.'
        );
        createOnce();
        Assert.areEqual(500, RestContext.response.statusCode, 'The failure is answered as an internal error');
        assertCreateUndone('Simulated ledger failure after the write');
    }

    private static void createOnce() {
        Test.startTest();
        post(
            '/create',
            new Map<String, Object>{
                'objectName' => 'Account',
                'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 'Half Written Account' } }
            },
            KEY
        );
        Test.stopTest();
    }

    private static void assertCreateUndone(String failureText) {
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Account WHERE Name = 'Half Written Account'],
            'A retry must not find the first attempt saved'
        );
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM AgentGov_Budget__c WHERE DML_Operations_Consumed__c > 0],
            'The charge for the undone write is undone too'
        );
        List<AgentGov_Action_Log__c> failures = [
            SELECT Details__c, Error_Message__c
            FROM AgentGov_Action_Log__c
            WHERE Action_Type__c = :AgentGovConstants.ACTION_SYSTEM AND Status__c = :AgentGovConstants.ACTION_FAILURE
        ];
        Boolean recorded = false;
        for (AgentGov_Action_Log__c failure : failures) {
            recorded = recorded || String.valueOf(failure.Error_Message__c).contains(failureText);
        }
        Assert.isTrue(recorded, 'The failure itself survives the rollback: ' + JSON.serialize(failures));
    }

    @IsTest
    static void aTrippedAgentCanWriteDuringTheEmergencyBypass() {
        AgentGov_Registration__c tripped = [
            SELECT Id
            FROM AgentGov_Registration__c
            WHERE Agent_Name__c = 'Proxy Test Agent'
        ];
        tripped.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        tripped.Status__c = AgentGovConstants.STATUS_BLOCKED;
        tripped.Cooldown_Until__c = DateTime.now().addHours(1);
        update tripped;
        AgentGov_Settings__c settings = [SELECT Id FROM AgentGov_Settings__c LIMIT 1];
        settings.Is_Enabled__c = false;
        update settings;
        AgentGovSelector.clearCache();

        post(
            '/create',
            new Map<String, Object>{
                'objectName' => 'Account',
                'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 'Written During Bypass' } }
            },
            KEY
        );

        Assert.areEqual(200, RestContext.response.statusCode, RestContext.response.responseBody.toString());
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Name = 'Written During Bypass']);
        Assert.areEqual(
            AgentGovConstants.CB_OPEN,
            [SELECT Circuit_Breaker_State__c FROM AgentGov_Registration__c WHERE Id = :tripped.Id]
            .Circuit_Breaker_State__c,
            'The bypass leaves the breaker as it was'
        );
    }

    private class SimulatedFailureException extends Exception {
    }

    @IsTest
    static void createConsumesBudgetByRecordCount() {
        List<Map<String, Object>> records = new List<Map<String, Object>>();
        for (Integer i = 0; i < 5; i++) {
            records.add(new Map<String, Object>{ 'Name' => 'Proxy Account ' + i });
        }

        Test.startTest();
        Map<String, Object> result = post(
            '/create',
            new Map<String, Object>{ 'objectName' => 'Account', 'records' => records },
            KEY
        );
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual(5, result.get('recordsSucceeded'));
        Assert.areEqual(true, result.get('allSucceeded'));
        Assert.areEqual(5, [SELECT COUNT() FROM Account WHERE Name LIKE 'Proxy Account %']);
        AgentGov_Registration__c reg = [
            SELECT Id
            FROM AgentGov_Registration__c
            WHERE Agent_Name__c = 'Proxy Test Agent'
        ];
        AgentGov_Budget__c budget = [
            SELECT DML_Operations_Consumed__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c = :reg.Id
        ];
        Assert.areEqual(5, budget.DML_Operations_Consumed__c, 'Budget reflects the real record count');
    }

    @IsTest
    static void unknownFieldOnWriteIsRejectedNotDropped() {
        post(
            '/create',
            new Map<String, Object>{
                'objectName' => 'Account',
                'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 'x', 'Not_A_Field__c' => 'y' } }
            },
            KEY
        );

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.areEqual(0, [SELECT COUNT() FROM Account]);
    }

    @IsTest
    static void updateRequiresIdOfMatchingType() {
        Account account = new Account(Name = 'Before');
        insert account;

        Map<String, Object> missingId = post(
            '/update',
            new Map<String, Object>{
                'objectName' => 'Account',
                'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 'After' } }
            },
            KEY
        );
        Assert.areEqual(400, RestContext.response.statusCode, JSON.serialize(missingId));

        Map<String, Object> wrongType = post(
            '/update',
            new Map<String, Object>{
                'objectName' => 'Contact',
                'records' => new List<Object>{ new Map<String, Object>{ 'Id' => account.Id, 'LastName' => 'After' } }
            },
            KEY
        );
        Assert.areEqual(400, RestContext.response.statusCode, JSON.serialize(wrongType));

        Map<String, Object> ok = post(
            '/update',
            new Map<String, Object>{
                'objectName' => 'Account',
                'records' => new List<Object>{ new Map<String, Object>{ 'Id' => account.Id, 'Name' => 'After' } }
            },
            KEY
        );
        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(ok));
        Assert.areEqual('After', [SELECT Name FROM Account WHERE Id = :account.Id].Name);
    }

    @IsTest
    static void deleteRemovesRecordsAndRejectsForeignIds() {
        Account account = new Account(Name = 'Doomed');
        insert account;
        Contact contact = new Contact(LastName = 'Survivor');
        insert contact;

        post(
            '/delete',
            new Map<String, Object>{ 'objectName' => 'Account', 'ids' => new List<Object>{ contact.Id } },
            KEY
        );
        Assert.areEqual(400, RestContext.response.statusCode, 'A Contact Id is not an Account');

        Map<String, Object> result = post(
            '/delete',
            new Map<String, Object>{ 'objectName' => 'Account', 'ids' => new List<Object>{ account.Id } },
            KEY
        );
        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual(1, result.get('recordsSucceeded'));
        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Id = :account.Id]);
    }

    @IsTest
    static void upsertCreatesAndUpdates() {
        Map<String, Object> created = post(
            '/upsert',
            new Map<String, Object>{
                'objectName' => 'Account',
                'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 'Upserted' } }
            },
            KEY
        );
        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(created));
        List<Object> results = (List<Object>) created.get('results');
        Map<String, Object> first = (Map<String, Object>) results[0];
        Assert.areEqual(true, first.get('created'));

        Map<String, Object> updated = post(
            '/upsert',
            new Map<String, Object>{
                'objectName' => 'Account',
                'records' => new List<Object>{
                    new Map<String, Object>{ 'Id' => first.get('id'), 'Name' => 'Upserted Again' }
                }
            },
            KEY
        );
        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(updated));
        Id createdId = (Id) first.get('id');
        Assert.areEqual('Upserted Again', [SELECT Name FROM Account WHERE Id = :createdId].Name);
    }

    @IsTest
    static void policyDenialIsLoggedAndReturned() {
        Test.startTest();
        Map<String, Object> result = post(
            '/delete',
            new Map<String, Object>{ 'objectName' => 'Account', 'ids' => new List<Object>{ '001000000000001AAA' } },
            MCP_KEY
        );
        Test.getEventBus().deliver();
        Test.stopTest();

        Assert.areEqual(403, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual('POLICY_VIOLATION', result.get('errorCode'));
        AgentGov_Registration__c reg = [
            SELECT Id
            FROM AgentGov_Registration__c
            WHERE Agent_Name__c = 'Proxy MCP Agent'
        ];
        Assert.areEqual(
            1,
            [
                SELECT COUNT()
                FROM AgentGov_Action_Log__c
                WHERE Agent_Registration__c = :reg.Id AND Status__c = :AgentGovConstants.ACTION_DENIED
            ],
            'The denial is written to the audit log'
        );
    }

    @IsTest
    static void openCircuitBreakerBlocksProxy() {
        AgentGov_Registration__c reg = [
            SELECT Id
            FROM AgentGov_Registration__c
            WHERE Agent_Name__c = 'Proxy Test Agent'
        ];
        reg.Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN;
        reg.Cooldown_Until__c = DateTime.now().addHours(1);
        update reg;

        Map<String, Object> result = post(
            '/query',
            queryBody('AgentGov_Registration__c', new List<String>{ 'Id' }),
            KEY
        );

        Assert.areEqual(503, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual('CIRCUIT_BREAKER_OPEN', result.get('errorCode'));
    }

    @IsTest
    static void invalidCredentialsReturnNotFound() {
        post('/query', queryBody('AgentGov_Registration__c', new List<String>{ 'Id' }), 'invalid-key');
        Assert.areEqual(
            404,
            RestContext.response.statusCode,
            'An unknown key does not reveal whether the agent exists'
        );

        post('/query', queryBody('AgentGov_Registration__c', new List<String>{ 'Id' }), null);
        Assert.areEqual(404, RestContext.response.statusCode, 'No key and no user binding cannot authenticate');
    }

    @IsTest
    static void bodyKeyStillWorksButIsFlaggedDeprecated() {
        Map<String, Object> body = queryBody('AgentGov_Registration__c', new List<String>{ 'Id' });
        body.put('apiKey', KEY);

        Map<String, Object> result = post('/query', body, null);

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
        Assert.isNotNull(result.get('deprecation'), 'Callers using the body key are told to move to the header');
    }

    @IsTest
    static void unknownEndpointAndMissingInputAreRejected() {
        post('/unknown', new Map<String, Object>{ 'apiKey' => KEY }, KEY);
        Assert.areEqual(404, RestContext.response.statusCode);

        post('/create', new Map<String, Object>{ 'records' => new List<Object>() }, KEY);
        Assert.areEqual(400, RestContext.response.statusCode);

        post('/create', new Map<String, Object>{ 'objectName' => 'Account' }, KEY);
        Assert.areEqual(400, RestContext.response.statusCode);

        post(
            '/query',
            new Map<String, Object>{ 'objectName' => 'No_Such_Object__c', 'fields' => new List<String>{ 'Id' } },
            KEY
        );
        Assert.areEqual(400, RestContext.response.statusCode);
    }

    @IsTest
    static void malformedJsonIsRejected() {
        RestRequest request = new RestRequest();
        request.requestURI = '/services/apexrest/agentgov-proxy/query';
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf('not json');
        request.addHeader(AgentGovConstants.REST_HEADER_API_KEY, KEY);
        RestContext.request = request;
        RestContext.response = new RestResponse();

        AgentGovProxyApi.doPost();

        Assert.areEqual(400, RestContext.response.statusCode);
    }
}
