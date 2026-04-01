@IsTest
private class AgentGovRestApiTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistrationWithApiKey(
            'REST Test Agent', 'MCP_External', 'rest-test-key-001'
        );
        // Activate the agent
        reg.Status__c = 'Active';
        update reg;
        AgentGovTestDataFactory.createBudget(reg.Id, true);
    }

    @IsTest
    static void testRegisterEndpoint() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/agentgov/register';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'agentName' => 'New REST Agent',
            'agentType' => 'MCP_External',
            'description' => 'Test agent',
            'apiKey' => 'new-rest-key-001',
            'ownerEmail' => 'test@test.com'
        }));

        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovRestApi.doPost();
        Test.stopTest();

        System.assertEquals(201, RestContext.response.statusCode, 'Should return 201 Created');
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(true, body.get('success'));
    }

    @IsTest
    static void testRegisterInvalidInput() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/agentgov/register';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'agentName' => '',
            'agentType' => 'Agentforce'
        }));

        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovRestApi.doPost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode, 'Should return 400 for invalid input');
    }

    @IsTest
    static void testAuthorizeEndpoint() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/agentgov/authorize';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'apiKey' => 'rest-test-key-001',
            'objectName' => 'Account',
            'operation' => 'Query',
            'recordId' => '001000000000001'
        }));

        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovRestApi.doPost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Should return 200 for authorized');
    }

    @IsTest
    static void testAuthorizeNoApiKey() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/agentgov/authorize';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'objectName' => 'Account',
            'operation' => 'Query'
        }));

        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovRestApi.doPost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void testAuthorizeUnknownApiKey() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/agentgov/authorize';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'apiKey' => 'unknown-key',
            'objectName' => 'Account',
            'operation' => 'Query'
        }));

        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovRestApi.doPost();
        Test.stopTest();

        System.assertEquals(404, RestContext.response.statusCode, 'Should return 404 for unknown agent');
    }

    @IsTest
    static void testGetBudgetEndpoint() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/agentgov/budget/' + reg.Id;
        req.httpMethod = 'GET';

        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovRestApi.doGet();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
    }

    @IsTest
    static void testGetHealthEndpoint() {
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c LIMIT 1];

        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/agentgov/health/' + reg.Id;
        req.httpMethod = 'GET';

        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovRestApi.doGet();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals('Active', body.get('status'));
    }

    @IsTest
    static void testGetUnknownEndpoint() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/agentgov/unknown';
        req.httpMethod = 'GET';

        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovRestApi.doGet();
        Test.stopTest();

        System.assertEquals(404, RestContext.response.statusCode);
    }

    @IsTest
    static void testPostUnknownEndpoint() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/agentgov/unknown';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('{}');

        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovRestApi.doPost();
        Test.stopTest();

        System.assertEquals(404, RestContext.response.statusCode);
    }
}
