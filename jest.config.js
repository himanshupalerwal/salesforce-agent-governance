const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

/**
 * Jest configuration for the AgentGov Lightning Web Components.
 * The mocks under force-app/test/jest-mocks replace platform modules that have no
 * implementation outside a Salesforce org.
 */
module.exports = {
    ...jestConfig,
    modulePathIgnorePatterns: ['<rootDir>/.localdevserver'],
    moduleNameMapper: {
        '^@salesforce/apex$': '<rootDir>/force-app/test/jest-mocks/salesforce/apex',
        '^lightning/navigation$': '<rootDir>/force-app/test/jest-mocks/lightning/navigation',
        '^lightning/platformShowToastEvent$': '<rootDir>/force-app/test/jest-mocks/lightning/platformShowToastEvent',
        '^lightning/empApi$': '<rootDir>/force-app/test/jest-mocks/lightning/empApi'
    },
    coverageThreshold: {
        global: {
            statements: 85,
            branches: 75,
            functions: 85,
            lines: 85
        }
    }
};
