/**
 * @description Resolves which registered agent is calling a REST endpoint.
 *
 *              Three credentials are accepted, in this order:
 *              1. An API key in the X-AgentGov-Key header (the legacy X-AgentGov-API-Key
 *                 header name is accepted as an alias).
 *              2. An API key in the request body's apiKey property. Supported for
 *                 compatibility with v1.1 clients, flagged as deprecated in every response,
 *                 and scheduled for removal in v1.4.
 *              3. No key at all, when the running user is bound to a registration through
 *                 Agent_User__c. This is the intended path for Agentforce Agent Users and
 *                 External Client App integration users: the OAuth identity is the credential.
 *                 A user bound to more than one registration must send a key, because the
 *                 login alone cannot say which agent is calling.
 *
 *              Keys are never stored. Only a SHA-256 hash and a short identifying prefix are
 *              kept on the registration. Keys are 256 random bits, so the hash is not salted;
 *              the salt in a password hash defends against guessable inputs, and these are
 *              not guessable. Plaintext keys stored by releases before v1.2 are upgraded to
 *              hashed storage the first time they are presented.
 *
 *              Security posture: inherited sharing. Reads go through AgentGovSelector and
 *              writes through AgentGovDml, both of which run in system mode.
 */
public inherited sharing class AgentGovRestAuth {
    private static Boolean bodyKeyUsed = false;

    /**
     * @description Resolves the calling agent from the request, upgrading legacy keys on the way.
     * @param request The current REST request
     * @param body The parsed JSON body, or null for requests without one
     * @return The calling agent's registration
     * @throws AgentGovException AGENT_NOT_FOUND when no credential resolves to a registration
     */
    public static AgentGov_Registration__c resolveRegistration(RestRequest request, Map<String, Object> body) {
        bodyKeyUsed = false;
        String apiKey = headerValue(request, AgentGovConstants.REST_HEADER_API_KEY);
        if (String.isBlank(apiKey)) {
            apiKey = headerValue(request, AgentGovConstants.REST_HEADER_API_KEY_LEGACY);
        }
        if (String.isBlank(apiKey) && body != null && body.get(AgentGovConstants.REST_BODY_API_KEY) != null) {
            apiKey = String.valueOf(body.get(AgentGovConstants.REST_BODY_API_KEY));
            bodyKeyUsed = String.isNotBlank(apiKey);
        }

        AgentGov_Registration__c registration;
        if (String.isNotBlank(apiKey)) {
            registration = resolveByKey(apiKey);
            if (registration == null) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.AGENT_NOT_FOUND,
                    AgentGovConstants.ERR_AGENT_NOT_REGISTERED
                );
            }
        } else {
            List<Id> boundIds = AgentGovSelector.getRegistrationIdsByAgentUser(UserInfo.getUserId());
            if (boundIds.isEmpty()) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.AGENT_NOT_FOUND,
                    AgentGovConstants.ERR_AUTH_REQUIRED
                );
            }
            // Picking one of several bound agents would charge and audit whichever was edited
            // most recently, so the caller must say which agent it is by sending its key.
            if (boundIds.size() > 1) {
                throw new AgentGovException(
                    AgentGovException.ErrorCode.ACCESS_DENIED,
                    AgentGovConstants.ERR_AMBIGUOUS_AGENT_USER
                );
            }
            registration = AgentGovSelector.getRegistrationById(boundIds[0]);
        }
        return registration;
    }

    /**
     * @description Ensures the agent may act. Active agents always may; Throttled agents may
     *              when the caller allows it (the proxy does, so a half-open breaker can probe).
     * @param registration The resolved registration
     * @param allowThrottled Whether Throttled status is acceptable
     * @return The same registration, for chaining
     * @throws AgentGovException AGENT_NOT_ACTIVE otherwise
     */
    public static AgentGov_Registration__c requireActive(
        AgentGov_Registration__c registration,
        Boolean allowThrottled
    ) {
        return requireActive(registration, allowThrottled, false);
    }

    /**
     * @description Ensures an agent may make a governed call.
     * @param registration The resolved calling agent
     * @param allowThrottled Admit Throttled, the status a HALF_OPEN breaker carries
     * @param allowBlockedProbe Admit Blocked when the circuit breaker says a probe is due.
     *                          Tripping leaves an agent Blocked, so without this the status
     *                          check refuses it before the breaker can readmit it and a
     *                          REST-only agent never recovers. The breaker still decides
     *                          whether this particular call is the single admitted probe.
     * @return The same registration once it is cleared to proceed
     * @throws AgentGovException AGENT_NOT_ACTIVE otherwise
     */
    public static AgentGov_Registration__c requireActive(
        AgentGov_Registration__c registration,
        Boolean allowThrottled,
        Boolean allowBlockedProbe
    ) {
        Boolean active = registration.Status__c == AgentGovConstants.STATUS_ACTIVE;
        Boolean throttled = allowThrottled && registration.Status__c == AgentGovConstants.STATUS_THROTTLED;
        Boolean probing = allowBlockedProbe && registration.Status__c == AgentGovConstants.STATUS_BLOCKED;
        if (!active && !throttled && !probing) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.AGENT_NOT_ACTIVE,
                AgentGovConstants.ERR_AGENT_NOT_ACTIVE
            );
        }
        return registration;
    }

    /**
     * @description Ensures the caller may read data about the given agent: either it is the
     *              caller's own registration or the caller holds the admin custom permission.
     * @param caller The resolved calling registration, or null when the caller is an admin user
     * @param targetRegistrationId The registration being read
     * @throws AgentGovException ACCESS_DENIED otherwise
     */
    public static void requireOwnerOrAdmin(AgentGov_Registration__c caller, Id targetRegistrationId) {
        if (hasAdminAccess()) {
            return;
        }
        if (caller != null && caller.Id == targetRegistrationId) {
            return;
        }
        throw new AgentGovException(
            AgentGovException.ErrorCode.ACCESS_DENIED,
            AgentGovConstants.ERR_ADMIN_ACCESS_REQUIRED
        );
    }

    /** @description True when the running user holds the AgentGov_Admin_Access custom permission. */
    public static Boolean hasAdminAccess() {
        return FeatureManagement.checkPermission(AgentGovConstants.CUSTOM_PERMISSION_ADMIN_ACCESS);
    }

    /** @description True when the most recent resolution used the deprecated body apiKey. */
    public static Boolean wasBodyKeyUsed() {
        return bodyKeyUsed;
    }

    /** @description Generates a new random API key. The caller must hand it to the agent; it is never stored. */
    public static String generateKey() {
        return AgentGovConstants.API_KEY_PREFIX + EncodingUtil.convertToHex(Crypto.generateAesKey(256));
    }

    /**
     * @description Hashes an API key for storage or lookup.
     * @param apiKey Plaintext key
     * @return Lowercase hex SHA-256 digest
     */
    public static String hashKey(String apiKey) {
        return EncodingUtil.convertToHex(
            Crypto.generateDigest(AgentGovConstants.API_KEY_HASH_ALGORITHM, Blob.valueOf(apiKey))
        );
    }

    /**
     * @description Returns the identifying prefix that is stored alongside the hash.
     * @param apiKey Plaintext key
     * @return The first characters of the key, enough to recognise it and too few to use it
     */
    public static String keyPrefix(String apiKey) {
        // The prefix is stored in a field the read-only dashboard permission set can read, so
        // it must never reveal enough of a key to be usable. New keys are held above the
        // minimum length by requireUsableKey, but keys inherited from v1.1 are not: they reach
        // this method through the lazy upgrade in resolveByKey and through the migration
        // script, and neither can reject a key without locking the agent out of its own org.
        // A key too short to truncate safely therefore gets no prefix at all. The prefix is
        // only a label for recognising a key in a list; losing it costs nothing.
        if (apiKey == null || apiKey.length() < AgentGovConstants.API_KEY_MINIMUM_LENGTH) {
            return null;
        }
        return apiKey.substring(0, AgentGovConstants.API_KEY_IDENTIFIER_LENGTH);
    }

    /**
     * @description Rejects a caller-supplied key that is too short to keep its prefix
     *              non-revealing.
     * @param apiKey Plaintext key supplied by the caller
     * @throws AgentGovException INVALID_INPUT when the key is shorter than the minimum
     */
    public static void requireUsableKey(String apiKey) {
        if (String.isNotBlank(apiKey) && apiKey.length() < AgentGovConstants.API_KEY_MINIMUM_LENGTH) {
            throw new AgentGovException(
                AgentGovException.ErrorCode.INVALID_INPUT,
                'apiKey must be at least ' + AgentGovConstants.API_KEY_MINIMUM_LENGTH + ' characters.'
            );
        }
    }

    /**
     * @description Writes a key's hash and prefix onto a registration and clears any legacy
     *              plaintext value. Does not perform DML; the caller persists the record.
     * @param registration Registration to update
     * @param apiKey Plaintext key
     */
    public static void applyKey(AgentGov_Registration__c registration, String apiKey) {
        registration.API_Key_Hash__c = hashKey(apiKey);
        registration.API_Key_Prefix__c = keyPrefix(apiKey);
        registration.API_Key_Last_Rotated__c = DateTime.now();
        registration.API_Key__c = null;
    }

    // --- Private helpers ---

    private static AgentGov_Registration__c resolveByKey(String apiKey) {
        AgentGov_Registration__c registration = AgentGovSelector.getRegistrationByApiKeyHash(hashKey(apiKey));
        if (registration != null) {
            return registration;
        }
        // A key that only matches the legacy plaintext column is upgraded in place so the
        // plaintext disappears the first time the agent connects after installing v1.2.
        AgentGov_Registration__c legacy = AgentGovSelector.getRegistrationByLegacyApiKey(apiKey);
        if (legacy != null) {
            applyKey(legacy, apiKey);
            AgentGovDml.updateRecord(legacy);
            AgentGovSelector.cacheRegistration(legacy);
        }
        return legacy;
    }

    private static String headerValue(RestRequest request, String headerName) {
        if (request == null || request.headers == null) {
            return null;
        }
        for (String name : request.headers.keySet()) {
            if (name.equalsIgnoreCase(headerName)) {
                return request.headers.get(name);
            }
        }
        return null;
    }
}
