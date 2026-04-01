@IsTest
private class AgentGovProxyApiTest {

    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Proxy Test Agent', AgentGovConstants.AGENT_TYPE_MCP_EXTERNAL, true);
        reg.Status__c = AgentGovConstants.STATUS_ACTIVE;
        reg.API_Key__c = 'proxy-test-key-001';
        update reg;
    }

    @IsTest
    static void testQueryEndpoint() {
        RestRequest req = new RestRequest();
        req.requestURI = '/agentgov-proxy/query';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'apiKey' => 'proxy-test-key-001',
            'query' => 'SELECT Id, Agent_Name__c FROM AgentGov_Registration__c LIMIT 5'
        }));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovProxyApi.doPost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Query should succeed');
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(true, result.get('success'), 'Should be successful');
        System.assertNotEquals(null, result.get('budgetStatus'), 'Should include budget status');
    }

    @IsTest
    static void testCreateEndpoint() {
        RestRequest req = new RestRequest();
        req.requestURI = '/agentgov-proxy/create';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'apiKey' => 'proxy-test-key-001',
            'objectName' => 'AgentGov_Action_Log__c',
            'records' => new List<Map<String, Object>>{
                new Map<String, Object>{
                    'Action_Type__c' => 'Query',
                    'Status__c' => 'Success',
                    'Timestamp__c' => DateTime.now()
                }
            }
        }));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovProxyApi.doPost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Create should succeed');
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(1, result.get('recordsSucceeded'), 'Should create 1 record');
    }

    @IsTest
    static void testDeleteEndpoint() {
        // Create a record to delete
        AgentGov_Action_Log__c log = new AgentGov_Action_Log__c(
            Action_Type__c = 'Query', Status__c = 'Success', Timestamp__c = DateTime.now()
        );
        insert log;

        RestRequest req = new RestRequest();
        req.requestURI = '/agentgov-proxy/delete';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'apiKey' => 'proxy-test-key-001',
            'objectName' => 'AgentGov_Action_Log__c',
            'ids' => new List<String>{ log.Id }
        }));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovProxyApi.doPost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Delete should succeed');
    }

    @IsTest
    static void testInvalidApiKey() {
        RestRequest req = new RestRequest();
        req.requestURI = '/agentgov-proxy/query';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'apiKey' => 'invalid-key',
            'query' => 'SELECT Id FROM AgentGov_Registration__c'
        }));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovProxyApi.doPost();
        Test.stopTest();

        System.assertEquals(404, RestContext.response.statusCode, 'Should return 404 for invalid key');
    }

    @IsTest
    static void testUnknownEndpoint() {
        RestRequest req = new RestRequest();
        req.requestURI = '/agentgov-proxy/unknown';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'apiKey' => 'proxy-test-key-001'
        }));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovProxyApi.doPost();
        Test.stopTest();

        System.assertEquals(404, RestContext.response.statusCode, 'Should return 404');
    }

    @IsTest
    static void testMissingObjectName() {
        RestRequest req = new RestRequest();
        req.requestURI = '/agentgov-proxy/create';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'apiKey' => 'proxy-test-key-001',
            'records' => new List<Map<String, Object>>()
        }));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovProxyApi.doPost();
        Test.stopTest();

        System.assert(RestContext.response.statusCode >= 400, 'Should return error for missing object');
    }

    @IsTest
    static void testBulkCreate() {
        List<Map<String, Object>> records = new List<Map<String, Object>>();
        for (Integer i = 0; i < 5; i++) {
            records.add(new Map<String, Object>{
                'Action_Type__c' => 'Query',
                'Status__c' => 'Success',
                'Timestamp__c' => DateTime.now()
            });
        }

        RestRequest req = new RestRequest();
        req.requestURI = '/agentgov-proxy/create';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'apiKey' => 'proxy-test-key-001',
            'objectName' => 'AgentGov_Action_Log__c',
            'records' => records
        }));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AgentGovProxyApi.doPost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Bulk create should succeed');
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(5, result.get('recordsProcessed'), 'Should process 5 records');
        System.assertEquals(5, result.get('recordsSucceeded'), 'All 5 should succeed');

        // Verify budget consumed by actual count (5, not 1)
        AgentGov_Registration__c reg = [SELECT Id FROM AgentGov_Registration__c WHERE API_Key__c = 'proxy-test-key-001'];
        AgentGov_Budget__c budget = [SELECT DML_Operations_Consumed__c FROM AgentGov_Budget__c WHERE Agent_Registration__c = :reg.Id AND Budget_Date__c = TODAY];
        System.assertEquals(5, budget.DML_Operations_Consumed__c, 'Budget should show 5 DML consumed, not 1');
    }
}
