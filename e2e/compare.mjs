#!/usr/bin/env node
/**
 * Compares two end-to-end result files check by check.
 *
 * Usage:
 *   npm run e2e:compare -- <before.json> <after.json>
 *   npm run e2e:compare -- --baseline <label>   newest file with that label against the newest file overall
 */
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const resultsDir = join(dirname(fileURLToPath(import.meta.url)), 'results');
const { values: options, positionals } = parseArgs({
    options: { baseline: { type: 'string' } },
    allowPositionals: true
});

function newest(filter = () => true) {
    const files = readdirSync(resultsDir)
        .filter((file) => file.endsWith('.json') && filter(file))
        .sort();
    if (!files.length) {
        throw new Error('No matching result files in e2e/results.');
    }
    return join(resultsDir, files.at(-1));
}

let [beforeFile, afterFile] = positionals;
if (!beforeFile || !afterFile) {
    if (!options.baseline) {
        console.error('Usage: npm run e2e:compare -- <before.json> <after.json>  or  -- --baseline <label>');
        process.exit(2);
    }
    beforeFile = newest((file) => file.includes(`-${options.baseline}`));
    afterFile = newest();
}

const load = (file) =>
    new Map(JSON.parse(readFileSync(file, 'utf8')).results.map((result) => [`${result.suite}:${result.id}`, result]));
const before = load(beforeFile);
const after = load(afterFile);

const groups = { fixed: [], regressed: [], stillFailing: [], stillPassing: [], added: [], removed: [] };
for (const [key, result] of after) {
    const previous = before.get(key);
    if (!previous) {
        groups.added.push(result);
    } else if (!previous.ok && result.ok) {
        groups.fixed.push(result);
    } else if (previous.ok && !result.ok) {
        groups.regressed.push(result);
    } else if (!result.ok) {
        groups.stillFailing.push(result);
    } else {
        groups.stillPassing.push(result);
    }
}
for (const [key, result] of before) {
    if (!after.has(key)) {
        groups.removed.push(result);
    }
}

const print = (title, list, withDetail = false) => {
    if (!list.length) {
        return;
    }
    console.log(`\n${title} (${list.length})`);
    for (const result of list) {
        console.log(
            `  ${result.suite}:${result.id.padEnd(4)} ${result.title}${result.ok ? '' : withDetail ? `\n        ${result.detail}` : ''}`
        );
    }
};

console.log(`Before: ${beforeFile}\nAfter:  ${afterFile}`);
print('Fixed: failed before, pass now', groups.fixed);
print('Regressed: passed before, fail now', groups.regressed, true);
print('Still failing', groups.stillFailing, true);
print('New checks', groups.added, true);
print('Checks no longer run', groups.removed);
console.log(`\nStill passing: ${groups.stillPassing.length}`);
process.exit(groups.regressed.length || groups.stillFailing.length ? 1 : 0);
