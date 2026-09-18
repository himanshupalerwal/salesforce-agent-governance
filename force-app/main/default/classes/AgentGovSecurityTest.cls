/**
 * @description Proves the access-mode split with a user who holds no access to AgentGov
 *              objects and no access to customer data: framework bookkeeping still succeeds
 *              in system mode, while operations on the agent's behalf are refused in user mode.
 */
@IsTest
private class AgentGovSecurityTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    private static Map<String, Object> postAs(String basePath, String path, Map<String, Object> body, Boolean proxy) {
        RestRequest request = new RestRequest();
        request.requestURI = '/services/apexrest' + basePath + path;
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf(JSON.serialize(body));
        RestContext.request = request;
        RestContext.response = new RestResponse();
        if (proxy) {
            AgentGovProxyApi.doPost();
        } else {
            AgentGovRestApi.doPost();
        }
        return (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
    }

    @IsTest
    static void boundAgentUserWithoutObjectAccessIsGovernedInSystemMode() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'Agent User Agent',
            'Agentforce',
            true
        );
        User agentUser = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Agent' });
        AgentGovRegistryService.bindAgentUser(reg.Id, agentUser.Id);

        Test.startTest();
        System.runAs(agentUser) {
            Map<String, Object> result = postAs(
                '/agentgov',
                '/authorize',
                new Map<String, Object>{ 'objectName' => 'Account', 'operation' => AgentGovConstants.ACTION_QUERY },
                false
            );
            Assert.areEqual(200, RestContext.response.statusCode, JSON.serialize(result));
            Assert.areEqual(true, result.get('authorized'));
        }
        Test.getEventBus().deliver();
        Test.stopTest();

        AgentGov_Budget__c budget = [
            SELECT SOQL_Queries_Consumed__c
            FROM AgentGov_Budget__c
            WHERE Agent_Registration__c = :reg.Id
        ];
        Assert.areEqual(
            1,
            budget.SOQL_Queries_Consumed__c,
            'The ledger is written although the user cannot see the object'
        );
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM AgentGov_Action_Log__c WHERE Agent_Registration__c = :reg.Id],
            'The audit row is written too'
        );
    }

    @IsTest
    static void proxyRefusesDataTheUserCannotAccess() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistrationWithApiKey(
            'Restricted Proxy Agent',
            'Custom_Apex',
            'restricted-key'
        );
        User agentUser = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_Agent' });
        AgentGovRegistryService.bindAgentUser(reg.Id, agentUser.Id);

        System.runAs(agentUser) {
            Map<String, Object> read = postAs(
                '/agentgov-proxy',
                '/query',
                new Map<String, Object>{
                    'objectName' => 'AgentGov_Registration__c',
                    'fields' => new List<String>{ 'Id', 'Agent_Name__c' }
                },
                true
            );
            Assert.areEqual(403, RestContext.response.statusCode, JSON.serialize(read));
            Assert.areEqual('ACCESS_DENIED', read.get('errorCode'));

            Map<String, Object> write = postAs(
                '/agentgov-proxy',
                '/create',
                new Map<String, Object>{
                    'objectName' => 'Account',
                    'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 'Blocked' } }
                },
                true
            );
            Assert.areEqual(403, RestContext.response.statusCode, JSON.serialize(write));
            Assert.areEqual('ACCESS_DENIED', write.get('errorCode'));
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Account], 'Nothing was written on the restricted user\'s behalf');
    }

    @IsTest
    static void dashboardControllerRespectsViewerAccess() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Visible Agent', 'Agentforce', true);
        AgentGovTestDataFactory.createBudget(reg.Id, true);
        User viewer = AgentGovTestDataFactory.createRestrictedUser(new List<String>{ 'AgentGov_User' });
        User outsider = AgentGovTestDataFactory.createRestrictedUser(new List<String>());

        System.runAs(viewer) {
            Assert.areEqual(
                1,
                AgentGovDashboardController.getAllRegistrations().size(),
                'The AgentGov User permission set grants the dashboard reads'
            );
            Assert.areEqual(1, AgentGovDashboardController.getAllTodaysBudgets().size());
        }
        System.runAs(outsider) {
            try {
                AgentGovDashboardController.getAllRegistrations();
                Assert.fail('A user without access must not see registrations');
            } catch (AuraHandledException e) {
                Assert.isTrue(
                    e.getMessage().contains('AgentGov User'),
                    'The message tells the viewer which permission set to ask for'
                );
            }
        }
    }
}
