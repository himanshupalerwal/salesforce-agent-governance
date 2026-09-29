'use strict';

/**
 * ESLint flat configuration for the AgentGov Lightning Web Components and the
 * end-to-end suite.
 *
 * Component sources use the Salesforce-recommended LWC rule set. Jest specs
 * and the shared Jest mocks additionally receive the Jest and Node globals,
 * and the wire-adapter rule is relaxed for specs because they exercise wire
 * adapters through the test utilities rather than real adapters. The
 * end-to-end suite is plain Node ES modules checked with the recommended rules.
 */
const { defineConfig } = require('eslint/config');
const eslintJs = require('@eslint/js');
const salesforceLwcConfig = require('@salesforce/eslint-config-lwc/recommended');
const jestPlugin = require('eslint-plugin-jest');
const globals = require('globals');

module.exports = defineConfig([
    {
        files: ['force-app/main/default/lwc/**/*.js'],
        ignores: ['force-app/main/default/lwc/**/__tests__/**'],
        extends: [salesforceLwcConfig]
    },
    {
        files: ['force-app/main/default/lwc/**/__tests__/**/*.js'],
        extends: [salesforceLwcConfig],
        plugins: { jest: jestPlugin },
        languageOptions: {
            globals: { ...globals.node, ...globals.jest }
        },
        rules: {
            '@lwc/lwc/no-unexpected-wire-adapter-usages': 'off',
            // Specs flush the microtask queue with setTimeout, which is fine outside a component.
            '@lwc/lwc/no-async-operation': 'off'
        }
    },
    {
        files: ['force-app/test/jest-mocks/**/*.js'],
        extends: [eslintJs.configs.recommended],
        languageOptions: {
            sourceType: 'module',
            ecmaVersion: 'latest',
            globals: { ...globals.node, ...globals.browser, ...globals.jest }
        }
    },
    {
        files: ['e2e/**/*.mjs'],
        extends: [eslintJs.configs.recommended],
        languageOptions: {
            sourceType: 'module',
            ecmaVersion: 'latest',
            globals: { ...globals.node }
        }
    },
    {
        ignores: ['e2e/results/**']
    }
]);
