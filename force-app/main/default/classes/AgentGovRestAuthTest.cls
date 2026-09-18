/**
 * @description Tests for AgentGovRestAuth: key hashing, header and body resolution, user
 *              binding, and the owner-or-admin guard.
 */
@IsTest
private class AgentGovRestAuthTest {
    @TestSetup
    static void setup() {
        AgentGovTestDataFactory.createSettings();
    }

    private static RestRequest requestWithHeader(String name, String value) {
        RestRequest request = new RestRequest();
        request.requestURI = '/services/apexrest/agentgov/authorize';
        request.httpMethod = 'POST';
        if (name != null) {
            request.addHeader(name, value);
        }
        return request;
    }

    @IsTest
    static void hashIsDeterministicSha256Hex() {
        String hash = AgentGovRestAuth.hashKey('example-key');
        Assert.areEqual(64, hash.length());
        Assert.areEqual(hash, AgentGovRestAuth.hashKey('example-key'));
        Assert.areNotEqual(hash, AgentGovRestAuth.hashKey('example-key-2'));
    }

    @IsTest
    static void generatedKeysArePrefixedRandomAndPrefixIsShort() {
        String first = AgentGovRestAuth.generateKey();
        String second = AgentGovRestAuth.generateKey();
        Assert.isTrue(first.startsWith(AgentGovConstants.API_KEY_PREFIX));
        Assert.areEqual(AgentGovConstants.API_KEY_PREFIX.length() + 64, first.length());
        Assert.areNotEqual(first, second);
        Assert.areEqual(AgentGovConstants.API_KEY_IDENTIFIER_LENGTH, AgentGovRestAuth.keyPrefix(first).length());
        // A key too short to truncate safely gets no prefix at all. Storing part of it would
        // put most of the secret in a field the read-only dashboard permission set can read,
        // and keys inherited from v1.1 reach this method through the lazy upgrade and the
        // migration script, neither of which can refuse a key without locking the agent out.
        Assert.isNull(AgentGovRestAuth.keyPrefix('short'), 'A key below the minimum length gets no prefix');
        Assert.isNull(AgentGovRestAuth.keyPrefix(null), 'A null key has no prefix');
    }

    @IsTest
    static void resolvesByHeaderCaseInsensitivelyAndByLegacyHeader() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistrationWithApiKey(
            'Header Agent',
            'Agentforce',
            'header-key'
        );

        AgentGov_Registration__c byHeader = AgentGovRestAuth.resolveRegistration(
            requestWithHeader('x-agentgov-key', 'header-key'),
            null
        );
        AgentGov_Registration__c byLegacyHeader = AgentGovRestAuth.resolveRegistration(
            requestWithHeader(AgentGovConstants.REST_HEADER_API_KEY_LEGACY, 'header-key'),
            null
        );

        Assert.areEqual(reg.Id, byHeader.Id);
        Assert.areEqual(reg.Id, byLegacyHeader.Id);
        Assert.isFalse(AgentGovRestAuth.wasBodyKeyUsed());
    }

    @IsTest
    static void resolvesByBodyKeyAndFlagsDeprecation() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistrationWithApiKey(
            'Body Agent',
            'Agentforce',
            'body-key'
        );

        AgentGov_Registration__c resolved = AgentGovRestAuth.resolveRegistration(
            requestWithHeader(null, null),
            new Map<String, Object>{ 'apiKey' => 'body-key' }
        );

        Assert.areEqual(reg.Id, resolved.Id);
        Assert.isTrue(AgentGovRestAuth.wasBodyKeyUsed());
    }

    @IsTest
    static void headerTakesPrecedenceOverBody() {
        AgentGov_Registration__c headerAgent = AgentGovTestDataFactory.createRegistrationWithApiKey(
            'Header Agent',
            'Agentforce',
            'h-key'
        );
        AgentGovTestDataFactory.createRegistrationWithApiKey('Body Agent', 'Agentforce', 'b-key');

        AgentGov_Registration__c resolved = AgentGovRestAuth.resolveRegistration(
            requestWithHeader(AgentGovConstants.REST_HEADER_API_KEY, 'h-key'),
            new Map<String, Object>{ 'apiKey' => 'b-key' }
        );

        Assert.areEqual(headerAgent.Id, resolved.Id);
    }

    @IsTest
    static void resolvesBoundUserWithoutKey() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Bound Agent', 'Agentforce', true);
        AgentGovRegistryService.bindAgentUser(reg.Id, UserInfo.getUserId());

        AgentGov_Registration__c resolved = AgentGovRestAuth.resolveRegistration(
            requestWithHeader(null, null),
            new Map<String, Object>()
        );

        Assert.areEqual(reg.Id, resolved.Id);
    }

    @IsTest
    static void unknownKeyAndUnboundUserAreRejected() {
        try {
            AgentGovRestAuth.resolveRegistration(
                requestWithHeader(AgentGovConstants.REST_HEADER_API_KEY, 'nope'),
                null
            );
            Assert.fail('Unknown key must be rejected');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.AGENT_NOT_FOUND, e.getErrorCode());
        }
        try {
            AgentGovRestAuth.resolveRegistration(requestWithHeader(null, null), null);
            Assert.fail('No credential must be rejected');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovConstants.ERR_AUTH_REQUIRED, e.getMessage());
        }
    }

    @IsTest
    static void requireActiveHonoursThrottledFlag() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration(
            'Throttled Agent',
            'Agentforce',
            false
        );
        reg.Status__c = AgentGovConstants.STATUS_THROTTLED;

        Assert.areEqual(reg, AgentGovRestAuth.requireActive(reg, true));
        try {
            AgentGovRestAuth.requireActive(reg, false);
            Assert.fail('Throttled is not Active when the caller does not allow it');
        } catch (AgentGovException e) {
            Assert.areEqual(AgentGovException.ErrorCode.AGENT_NOT_ACTIVE, e.getErrorCode());
        }
    }

    @IsTest
    static void ownerOrAdminGuard() {
        AgentGov_Registration__c own = AgentGovTestDataFactory.createRegistration('Own Agent', 'Agentforce', true);
        AgentGov_Registration__c other = AgentGovTestDataFactory.createRegistration('Other Agent', 'Agentforce', true);
        User restricted = AgentGovTestDataFactory.createRestrictedUser(new List<String>());

        System.runAs(restricted) {
            AgentGovRestAuth.requireOwnerOrAdmin(own, own.Id);
            try {
                AgentGovRestAuth.requireOwnerOrAdmin(own, other.Id);
                Assert.fail('Reading another agent needs the admin permission');
            } catch (AgentGovException e) {
                Assert.areEqual(AgentGovException.ErrorCode.ACCESS_DENIED, e.getErrorCode());
            }
        }
    }

    @IsTest
    static void applyKeyClearsPlaintext() {
        AgentGov_Registration__c reg = AgentGovTestDataFactory.createRegistration('Apply Agent', 'Agentforce', false);
        reg.API_Key__c = 'old-plaintext';

        AgentGovRestAuth.applyKey(reg, 'new-key');

        Assert.isNull(reg.API_Key__c);
        Assert.areEqual(AgentGovRestAuth.hashKey('new-key'), reg.API_Key_Hash__c);
        Assert.isNotNull(reg.API_Key_Last_Rotated__c);
    }
}
