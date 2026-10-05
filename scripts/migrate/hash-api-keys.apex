// AgentGov migration for orgs upgrading from v1.1: move plaintext API keys to hashed storage.
//
// Releases before v1.2 stored each agent's API key in API_Key__c. v1.2 stores only a
// SHA-256 hash (API_Key_Hash__c) plus an identifying prefix, and upgrades legacy keys
// lazily the first time each agent connects. Run this script once after deploying v1.2 or
// any later release to upgrade every remaining plaintext key immediately instead of waiting
// for that first connection. It is safe to run more than once.
//
// A key too short to truncate safely is stored with no identifying prefix, because the
// prefix field is readable by everyone holding AgentGov_User and a short key's prefix
// would be the whole key. Rotate those keys afterwards with POST /agentgov/rotate-key.
//
// Run with: sf apex run --file scripts/migrate/hash-api-keys.apex --target-org <alias>

List<AgentGov_Registration__c> legacy = [
    SELECT Id, API_Key__c
    FROM AgentGov_Registration__c
    WHERE API_Key__c != NULL
    LIMIT 10000
];
for (AgentGov_Registration__c registration : legacy) {
    AgentGovRestAuth.applyKey(registration, registration.API_Key__c);
}
update legacy;
Integer withoutPrefix = 0;
for (AgentGov_Registration__c registration : legacy) {
    if (registration.API_Key_Prefix__c == null) {
        withoutPrefix++;
    }
}
System.debug(
    LoggingLevel.INFO,
    'AgentGov: upgraded ' +
        legacy.size() +
        ' plaintext API key(s) to hashed storage. ' +
        withoutPrefix +
        ' were too short to keep an identifying prefix and should be rotated.'
);
