const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

/**
 * Jest configuration for the AgentGov Lightning Web Components.
 * The mocks under force-app/test/jest-mocks replace platform modules that have no
 * implementation outside a Salesforce org. Each custom permission maps to its own mock so a
 * spec can revoke one without the other.
 */
module.exports = {
    ...jestConfig,
    modulePathIgnorePatterns: ['<rootDir>/.localdevserver'],
    // The end-to-end suite runs against a real org through e2e/run.mjs, never under Jest.
    testPathIgnorePatterns: [...(jestConfig.testPathIgnorePatterns ?? []), '<rootDir>/e2e/'],
    moduleNameMapper: {
        // A CSS-only module has no JavaScript entry for the default resolver to find.
        '^c/agentGovStyles$': '<rootDir>/force-app/main/default/lwc/agentGovStyles/agentGovStyles.css',
        '^@salesforce/apex$': '<rootDir>/force-app/test/jest-mocks/salesforce/apex',
        '^@salesforce/customPermission/AgentGov_Operate_Agents$':
            '<rootDir>/force-app/test/jest-mocks/salesforce/customPermission/AgentGov_Operate_Agents',
        '^@salesforce/customPermission/AgentGov_Manage_Keys$':
            '<rootDir>/force-app/test/jest-mocks/salesforce/customPermission/AgentGov_Manage_Keys',
        '^lightning/navigation$': '<rootDir>/force-app/test/jest-mocks/lightning/navigation',
        '^lightning/platformShowToastEvent$': '<rootDir>/force-app/test/jest-mocks/lightning/platformShowToastEvent',
        '^lightning/empApi$': '<rootDir>/force-app/test/jest-mocks/lightning/empApi',
        '^lightning/confirm$': '<rootDir>/force-app/test/jest-mocks/lightning/confirm',
        '^lightning/modal$': '<rootDir>/force-app/test/jest-mocks/lightning/modal'
    },
    // Coverage is measured on the components' JavaScript. The preset's catch-all pattern also
    // matches the shared stylesheet module, which has no script, and that emptied the report
    // and left the threshold below unenforced.
    collectCoverageFrom: ['force-app/main/default/lwc/**/*.js', '!force-app/main/default/lwc/**/__tests__/**'],
    coverageThreshold: {
        global: {
            statements: 85,
            branches: 75,
            functions: 85,
            lines: 85
        }
    }
};
