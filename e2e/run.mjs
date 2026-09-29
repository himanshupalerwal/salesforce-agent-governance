#!/usr/bin/env node
/**
 * Runs the AgentGov end-to-end suite against a real scratch org and prints a pass/fail table.
 *
 * Usage:
 *   npm run e2e -- --target-org <alias>   run against an existing scratch org
 *   npm run e2e                            create a temporary scratch org, delete it afterwards
 *
 * Options:
 *   --suites api,traffic,ui   parts to run after setup (default: api,traffic,ui)
 *   --no-deploy               skip the source deploy because the org already has this code
 *   --keep                    keep a temporary org instead of deleting it
 *   --dev-hub <alias>         Dev Hub for a temporary org (default: the CLI's default Dev Hub)
 *   --label <name>            label for the saved results file, for example baseline-v1.2
 *
 * Results are written to e2e/results/ so two runs can be compared with e2e/compare.mjs.
 */
import { parseArgs } from 'node:util';
import { printTable, redact, saveResults } from './lib/checks.mjs';
import { sf } from './lib/sf.mjs';
import { prepareOrg } from './setup.mjs';

const { values: options } = parseArgs({
    options: {
        'target-org': { type: 'string' },
        suites: { type: 'string', default: 'api,traffic,ui' },
        'no-deploy': { type: 'boolean', default: false },
        keep: { type: 'boolean', default: false },
        'dev-hub': { type: 'string' },
        label: { type: 'string' }
    }
});

const suites = options.suites.split(',').map((name) => name.trim());
const runId = Date.now().toString(36);
let targetOrg = options['target-org'];
let temporary = false;

if (!targetOrg) {
    targetOrg = `agentgov-e2e-${runId}`;
    temporary = true;
    console.log(`> Creating temporary scratch org ${targetOrg}`);
    const args = [
        'org',
        'create',
        'scratch',
        '--definition-file',
        'config/project-scratch-def.json',
        '--alias',
        targetOrg,
        '--duration-days',
        '1',
        '--wait',
        '30'
    ];
    if (options['dev-hub']) {
        args.push('--target-dev-hub', options['dev-hub']);
    }
    sf(args);
}

let results = [];
let exitCode = 1;
try {
    const context = { ...(await prepareOrg({ targetOrg, deploy: !options['no-deploy'] })), runId };
    for (const suite of suites) {
        console.log(`\n> Running the ${suite} suite`);
        const module = await import(`./${suite}.mjs`);
        const run = module.runApiSuite ?? module.runTrafficSuite ?? module.runUiSuite;
        results = results.concat(await run(context));
    }
    const failures = printTable(results);
    const file = saveResults(results, { label: options.label, targetOrg: temporary ? 'temporary' : targetOrg, runId });
    console.log(`Results saved to ${file}`);
    exitCode = failures === 0 ? 0 : 1;
} catch (error) {
    if (results.length) {
        printTable(results);
    }
    console.error(`\nThe suite stopped: ${redact(error.message)}`);
} finally {
    if (temporary && !options.keep) {
        console.log(`\n> Deleting temporary scratch org ${targetOrg}`);
        sf(['org', 'delete', 'scratch', '--target-org', targetOrg, '--no-prompt'], { allowFail: true });
    }
}
process.exit(exitCode);
