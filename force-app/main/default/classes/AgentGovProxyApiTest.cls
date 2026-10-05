/**
 * @description Tests for the governed proxy: structured queries, injection resistance,
 *              write validation, the order in which a request is validated and governed,
 *              policy enforcement, access checks, and budget accounting.
 */
@IsTest
private class AgentGovProxyApiTest {
    private static final String KEY = 'proxy-test-key-001';
    private static final String MCP_KEY = 'proxy-mcp-key-002';
    private static final String PROXY_AGENT = 'Proxy Test Agent';

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

    private static AgentGov_Registration__c proxyAgent() {
        return [
            SELECT Id, Circuit_Breaker_State__c, Status__c, Half_Open_Probe_At__c, Failure_Count__c
            FROM AgentGov_Registration__c
            WHERE Agent_Name__c = :PROXY_AGENT
        ];
    }

    private static Integer chargedBudgetRows() {
        return [
            SELECT COUNT()
            FROM AgentGov_Budget__c
            WHERE SOQL_Queries_Consumed__c > 0 OR DML_Operations_Consumed__c > 0 OR API_Calls_Consumed__c > 0
        ];
    }

    private static void assertRefused(Integer status, String errorCode, String message, Map<String, Object> result) {
        Assert.areEqual(status, RestContext.response.statusCode, JSON.serialize(result));
        Assert.areEqual(errorCode, result.get('errorCode'));
        Assert.areEqual(message, result.get('message'));
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
        Assert.areEqual(
            AgentGovConstants.ERR_RAW_SOQL_UNSUPPORTED,
            result.get('message'),
            'The error explains the migration'
        );
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
        Map<String, Object> result = createOnce();
        Assert.areEqual(500, RestContext.response.statusCode, 'The failure is answered as an internal error');
        assertCreateUndone('Simulated failure after the write', result);
    }

    @IsTest
    static void anInternalErrorAfterTheWriteIsUndoneToo() {
        // An INTERNAL_ERROR raised as an AgentGovException, such as a breaker update that fails
        // after the records were saved, also answers 500 and must leave nothing behind.
        AgentGovProxyApi.failureAfterWrite = new AgentGovException(
            AgentGovException.ErrorCode.INTERNAL_ERROR,
            'Simulated ledger failure after the write.'
        );
        Map<String, Object> result = createOnce();
        Assert.areEqual(500, RestContext.response.statusCode, 'The failure is answered as an internal error');
        assertCreateUndone('Simulated ledger failure after the write', result);
    }

    private static Map<String, Object> createOnce() {
        Test.startTest();
        Map<String, Object> result = post(
            '/create',
            new Map<String, Object>{
                'objectName' => 'Account',
                'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 'Half Written Account' } }
            },
            KEY
        );
        Test.stopTest();
        return result;
    }

    private static void assertCreateUndone(String failureText, Map<String, Object> result) {
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
            SELECT Details__c, Error_Message__c, Correlation_Id__c
            FROM AgentGov_Action_Log__c
            WHERE Action_Type__c = :AgentGovConstants.ACTION_SYSTEM AND Status__c = :AgentGovConstants.ACTION_FAILURE
        ];
        Assert.areEqual(1, failures.size(), 'One failure leaves exactly one System row: ' + JSON.serialize(failures));
        Assert.isTrue(
            String.valueOf(failures[0].Error_Message__c).contains(failureText),
            'The failure itself survives the rollback: ' + JSON.serialize(failures)
        );
        Assert.areEqual(result.get('correlationId'), failures[0].Correlation_Id__c, 'The row is under the request id');
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

    private static List<Map<String, Object>> malformedRequests(Id accountId) {
        Map<String, Object> notFilterable = queryBody('Account', new List<String>{ 'Id' });
        notFilterable.put('where', new List<Object>{ condition('Description', '=', 'x') });
        Map<String, Object> notSortable = queryBody('Account', new List<String>{ 'Id' });
        notSortable.put('orderBy', new Map<String, Object>{ 'field' => 'Description' });
        List<Object> sameRecordTwice = new List<Object>{
            new Map<String, Object>{ 'Id' => accountId, 'Name' => 'First' },
            new Map<String, Object>{ 'Id' => accountId, 'Name' => 'Second' }
        };
        return new List<Map<String, Object>>{
            new Map<String, Object>{
                'path' => '/query',
                'body' => queryBody('Account', new List<String>{ 'No_Such_Field__c' })
            },
            new Map<String, Object>{ 'path' => '/query', 'body' => notFilterable },
            new Map<String, Object>{ 'path' => '/query', 'body' => notSortable },
            new Map<String, Object>{
                'path' => '/update',
                'body' => new Map<String, Object>{ 'objectName' => 'Account', 'records' => sameRecordTwice }
            },
            new Map<String, Object>{
                'path' => '/delete',
                'body' => new Map<String, Object>{
                    'objectName' => 'Account',
                    'ids' => new List<Object>{ accountId, accountId }
                }
            },
            new Map<String, Object>{
                'path' => '/upsert',
                'body' => new Map<String, Object>{
                    'objectName' => 'Account',
                    'externalIdField' => 'Industry',
                    'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 'x' } }
                }
            },
            new Map<String, Object>{
                'path' => '/create',
                'body' => new Map<String, Object>{
                    'objectName' => 'Account',
                    'records' => new List<Object>{
                        new Map<String, Object>{ 'Name' => new Map<String, Object>{ 'first' => 'x' } }
                    }
                }
            }
        };
    }

    @IsTest
    static void aMalformedRequestLeavesAHalfOpenBreakersProbeForTheNextRequest() {
        AgentGov_Registration__c agent = proxyAgent();
        update new AgentGov_Registration__c(
            Id = agent.Id,
            Circuit_Breaker_State__c = AgentGovConstants.CB_HALF_OPEN,
            Status__c = AgentGovConstants.STATUS_THROTTLED,
            Half_Open_Probe_At__c = null
        );
        Account account = new Account(Name = 'Probe Target');
        insert account;

        Test.startTest();
        for (Map<String, Object> malformed : malformedRequests(account.Id)) {
            Map<String, Object> result = post(
                (String) malformed.get('path'),
                (Map<String, Object>) malformed.get('body'),
                KEY
            );
            Assert.areEqual(400, RestContext.response.statusCode, malformed.get('path') + ' ' + JSON.serialize(result));
            AgentGov_Registration__c waiting = proxyAgent();
            Assert.areEqual(AgentGovConstants.CB_HALF_OPEN, waiting.Circuit_Breaker_State__c);
            Assert.isNull(waiting.Half_Open_Probe_At__c, 'A malformed request never claims the probe: ' + result);
        }
        Map<String, Object> probe = post('/query', queryBody('Account', new List<String>{ 'Id' }), KEY);
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(probe));
        AgentGov_Registration__c closed = proxyAgent();
        Assert.areEqual(
            AgentGovConstants.CB_CLOSED,
            closed.Circuit_Breaker_State__c,
            'The first well-formed request was the probe, and its success closed the breaker'
        );
        Assert.areEqual(AgentGovConstants.STATUS_ACTIVE, closed.Status__c);
        AgentGov_Budget__c budget = [
            SELECT SOQL_Queries_Consumed__c, DML_Operations_Consumed__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c = :agent.Id
        ];
        Assert.areEqual(1, budget.SOQL_Queries_Consumed__c, 'Only the probe was charged');
        Assert.areEqual(0, budget.DML_Operations_Consumed__c, 'No malformed write was charged');
        Assert.areEqual(
            0,
            [
                SELECT COUNT()
                FROM AgentGov_Action_Log__c
                WHERE Agent_Registration__c = :agent.Id AND Status__c != :AgentGovConstants.ACTION_SUCCESS
            ],
            'A malformed request leaves no audit row'
        );
        Assert.areEqual('Probe Target', [SELECT Name FROM Account WHERE Id = :account.Id].Name);
    }

    @IsTest
    static void aMalformedRequestLeavesAnOpenBreakerForTheNextRequest() {
        AgentGov_Registration__c agent = proxyAgent();
        update new AgentGov_Registration__c(
            Id = agent.Id,
            Circuit_Breaker_State__c = AgentGovConstants.CB_OPEN,
            Status__c = AgentGovConstants.STATUS_BLOCKED,
            Cooldown_Until__c = DateTime.now().addMinutes(-5)
        );

        post('/query', queryBody('Account', new List<String>{ 'No_Such_Field__c' }), KEY);

        Assert.areEqual(400, RestContext.response.statusCode);
        AgentGov_Registration__c untouched = proxyAgent();
        Assert.areEqual(AgentGovConstants.CB_OPEN, untouched.Circuit_Breaker_State__c, 'The breaker was not consulted');
        Assert.areEqual(AgentGovConstants.STATUS_BLOCKED, untouched.Status__c);
        Assert.isNull(untouched.Half_Open_Probe_At__c);
    }

    @IsTest
    static void aQueryTheDatabaseRefusesIsNotChargedAndLeavesTheProbe() {
        AgentGov_Registration__c agent = proxyAgent();
        update new AgentGov_Registration__c(
            Id = agent.Id,
            Circuit_Breaker_State__c = AgentGovConstants.CB_HALF_OPEN,
            Status__c = AgentGovConstants.STATUS_THROTTLED,
            Half_Open_Probe_At__c = null
        );
        // Boolean fields take only = and !=. The builder leaves that rule to the database, so
        // this query passes every check and is refused only when it runs.
        Map<String, Object> refusedByDatabase = queryBody('Account', new List<String>{ 'Id' });
        refusedByDatabase.put('where', new List<Object>{ condition('IsDeleted', '<', true) });

        Test.startTest();
        assertRefused(
            400,
            'INVALID_INPUT',
            String.format(AgentGovConstants.ERR_QUERY_NOT_RUN, new List<String>{ 'Account' }),
            post('/query', refusedByDatabase, KEY)
        );
        AgentGov_Registration__c waiting = proxyAgent();
        Integer chargedAfterRefusal = chargedBudgetRows();
        AgentGovSelector.clearCache();
        Map<String, Object> probe = post('/query', queryBody('Account', new List<String>{ 'Id' }), KEY);
        Test.stopTest();

        Assert.areEqual(AgentGovConstants.CB_HALF_OPEN, waiting.Circuit_Breaker_State__c);
        Assert.isNull(waiting.Half_Open_Probe_At__c, 'The refused query gave back the probe it had claimed');
        Assert.areEqual(0, chargedAfterRefusal, 'The refused query was not charged');
        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(probe));
        Assert.areEqual(AgentGovConstants.CB_CLOSED, proxyAgent().Circuit_Breaker_State__c);
        Assert.areEqual(
            1,
            [SELECT SOQL_Queries_Consumed__c FROM AgentGov_Budget__c WHERE Agent_Registration__c = :agent.Id]
            .SOQL_Queries_Consumed__c
        );
    }

    @IsTest
    static void aFieldTheUserCannotReadIsRefusedBeforeTheQueryIsCharged() {
        // AgentGov_User reads registrations but not the stored key hash.
        User reader = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_User' });
        Map<String, Object> selectsHash = queryBody(
            'AgentGov_Registration__c',
            new List<String>{ 'Id', 'API_Key_Hash__c' }
        );
        Map<String, Object> filtersOnHash = queryBody('AgentGov_Registration__c', new List<String>{ 'Id' });
        filtersOnHash.put('where', new List<Object>{ condition('API_Key_Hash__c', '=', 'x') });
        String refusal = String.format(
            AgentGovConstants.ERR_FIELDS_NOT_ACCESSIBLE,
            new List<String>{ 'read', 'AgentGov_Registration__c', 'API_Key_Hash__c' }
        );

        Test.startTest();
        System.runAs(reader) {
            assertRefused(403, 'ACCESS_DENIED', refusal, post('/query', selectsHash, KEY));
            assertRefused(403, 'ACCESS_DENIED', refusal, post('/query', filtersOnHash, KEY));
        }
        Test.stopTest();

        Assert.areEqual(0, chargedBudgetRows(), 'A query refused for access is not charged');
        Assert.areEqual(
            2,
            [
                SELECT COUNT()
                FROM AgentGov_Action_Log__c
                WHERE
                    Agent_Registration__c = :proxyAgent().Id
                    AND Action_Type__c = :AgentGovConstants.ACTION_QUERY
                    AND Status__c = :AgentGovConstants.ACTION_DENIED
            ],
            'Each refusal is audited'
        );
    }

    @IsTest
    static void anObjectTheUserCannotReadIsRefusedBeforeTheQueryIsCharged() {
        User restricted = AgentGovTestDataFactory.createRestrictedUser(new List<String>());

        System.runAs(restricted) {
            assertRefused(
                403,
                'ACCESS_DENIED',
                String.format(AgentGovConstants.ERR_OBJECT_NOT_ACCESSIBLE, new List<String>{ 'read', 'Account' }),
                post('/query', queryBody('Account', new List<String>{ 'Id', 'Name' }), KEY)
            );
        }

        Assert.areEqual(0, chargedBudgetRows(), 'A query refused for access is not charged');
    }

    @IsTest
    static void aDeleteTheUserMayNotMakeIsRefusedBeforeItIsCharged() {
        Account account = new Account(Name = 'Kept');
        insert account;
        User restricted = AgentGovTestDataFactory.createRestrictedUser(new List<String>());

        Test.startTest();
        System.runAs(restricted) {
            assertRefused(
                403,
                'ACCESS_DENIED',
                String.format(AgentGovConstants.ERR_OBJECT_NOT_ACCESSIBLE, new List<String>{ 'delete', 'Account' }),
                post(
                    '/delete',
                    new Map<String, Object>{ 'objectName' => 'Account', 'ids' => new List<Object>{ account.Id } },
                    KEY
                )
            );
        }
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Id = :account.Id]);
        Assert.areEqual(0, chargedBudgetRows(), 'A delete refused for access is not charged');
        AgentGov_Registration__c agent = proxyAgent();
        Assert.areEqual(0, agent.Failure_Count__c, 'A refusal is not a failure the circuit breaker counts');
        Assert.areEqual(
            1,
            [
                SELECT COUNT()
                FROM AgentGov_Action_Log__c
                WHERE
                    Agent_Registration__c = :agent.Id
                    AND Action_Type__c = :AgentGovConstants.ACTION_DELETE
                    AND Status__c = :AgentGovConstants.ACTION_DENIED
            ]
        );
    }

    @IsTest
    static void aWriteThatNamesARecordTwiceIsRefusedBeforeAnythingRuns() {
        Account account = new Account(Name = 'Named Twice');
        insert account;
        // The 15-character form names the same record as the 18-character one.
        String shortId = String.valueOf(account.Id).left(15);
        List<Object> sameRecordTwice = new List<Object>{
            new Map<String, Object>{ 'Id' => account.Id, 'Name' => 'First' },
            new Map<String, Object>{ 'Id' => shortId, 'Name' => 'Second' }
        };
        String refusal = String.format(
            AgentGovConstants.ERR_DUPLICATE_RECORD_ID,
            new List<String>{ String.valueOf(account.Id) }
        );

        for (String path : new List<String>{ '/update', '/upsert' }) {
            assertRefused(
                400,
                'INVALID_INPUT',
                refusal,
                post(path, new Map<String, Object>{ 'objectName' => 'Account', 'records' => sameRecordTwice }, KEY)
            );
        }
        assertRefused(
            400,
            'INVALID_INPUT',
            refusal,
            post(
                '/delete',
                new Map<String, Object>{ 'objectName' => 'Account', 'ids' => new List<Object>{ account.Id, shortId } },
                KEY
            )
        );

        Assert.areEqual('Named Twice', [SELECT Name FROM Account WHERE Id = :account.Id].Name);
        Assert.areEqual(0, chargedBudgetRows(), 'Nothing was charged');
    }

    @IsTest
    static void aNumberForATextFieldIsWrittenAndMatchedAsText() {
        Map<String, Object> created = post(
            '/create',
            new Map<String, Object>{
                'objectName' => 'Account',
                'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 12345 } }
            },
            KEY
        );
        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(created));
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Name = '12345']);

        Map<String, Object> query = queryBody('Account', new List<String>{ 'Id', 'Name' });
        query.put('where', new List<Object>{ condition('Name', '=', 12345) });
        Map<String, Object> found = post('/query', query, KEY);

        Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(found));
        Assert.areEqual(1, found.get('totalSize'));
    }

    @IsTest
    static void aValueOfTheWrongJsonTypeIsBadInputNotAnInternalError() {
        assertRefused(
            400,
            'INVALID_INPUT',
            String.format(AgentGovConstants.ERR_NOT_A_STRING, new List<String>{ 'objectName' }),
            post(
                '/create',
                new Map<String, Object>{
                    'objectName' => new List<Object>{ 'Account' },
                    'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 'x' } }
                },
                KEY
            )
        );
        assertRefused(
            400,
            'INVALID_INPUT',
            String.format(AgentGovConstants.ERR_NOT_A_STRING, new List<String>{ 'objectName' }),
            post('/query', new Map<String, Object>{ 'objectName' => 7, 'fields' => new List<String>{ 'Id' } }, KEY)
        );
        assertRefused(
            400,
            'INVALID_INPUT',
            String.format(AgentGovConstants.ERR_NOT_A_STRING, new List<String>{ 'externalIdField' }),
            post(
                '/upsert',
                new Map<String, Object>{
                    'objectName' => 'Account',
                    'externalIdField' => 5,
                    'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 'x' } }
                },
                KEY
            )
        );
        assertRefused(
            400,
            'INVALID_INPUT',
            String.format(AgentGovConstants.ERR_VALUE_NOT_SCALAR, new List<String>{ 'STRING' }),
            post(
                '/create',
                new Map<String, Object>{
                    'objectName' => 'Account',
                    'records' => new List<Object>{
                        new Map<String, Object>{ 'Name' => new Map<String, Object>{ 'first' => 'x' } }
                    }
                },
                KEY
            )
        );
        // An audit field no request may set.
        assertRefused(
            400,
            'INVALID_INPUT',
            String.format(AgentGovConstants.ERR_FIELD_NOT_SETTABLE, new List<String>{ 'Account', 'CreatedDate' }),
            post(
                '/create',
                new Map<String, Object>{
                    'objectName' => 'Account',
                    'records' => new List<Object>{
                        new Map<String, Object>{ 'Name' => 'x', 'CreatedDate' => '2026-01-01T00:00:00.000Z' }
                    }
                },
                KEY
            )
        );

        Assert.areEqual(0, [SELECT COUNT() FROM Account], 'Nothing was written');
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM AgentGov_Action_Log__c WHERE Action_Type__c = :AgentGovConstants.ACTION_SYSTEM],
            'No request failed as an internal error'
        );
    }

    @IsTest
    static void aWriteOverTheRequestMaximumIsRefusedBeforeItIsBuilt() {
        Integer maximum = Limits.getLimitDmlRows();
        List<Object> ids = new List<Object>();
        List<Object> records = new List<Object>();
        for (Integer i = 0; i <= maximum; i++) {
            ids.add('001000000000001AAA');
            records.add(new Map<String, Object>());
        }
        String refusal = String.format(
            AgentGovConstants.ERR_TOO_MANY_RECORDS,
            new List<String>{ String.valueOf(maximum), String.valueOf(maximum + 1) }
        );

        assertRefused(
            400,
            'INVALID_INPUT',
            refusal,
            post('/delete', new Map<String, Object>{ 'objectName' => 'Account', 'ids' => ids }, KEY)
        );
        assertRefused(
            400,
            'INVALID_INPUT',
            refusal,
            post('/create', new Map<String, Object>{ 'objectName' => 'Account', 'records' => records }, KEY)
        );
        Assert.areEqual(0, chargedBudgetRows());
    }
}
