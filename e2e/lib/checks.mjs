/**
 * Check recording and reporting for the end-to-end suite.
 *
 * A check is one claim about the deployed system, with a stable id so that runs against
 * different versions can be compared claim by claim.
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const resultsDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'results');

/** Thrown by ensure(); its message becomes the failure detail. */
export class CheckFailure extends Error {}

/** Fails the enclosing check with the given explanation when the condition is false. */
export function ensure(condition, message) {
    if (!condition) {
        throw new CheckFailure(message);
    }
}

/**
 * Removes every URL from a failure detail. Browser and CLI errors can quote the address they
 * navigated to, and a Salesforce login address carries a session id, which must never reach a
 * results file or a terminal.
 */
export function redact(text) {
    return String(text).replace(/\b[a-z][a-z0-9+.-]*:\/\/\S+/gi, '<url removed>');
}

/** Collects the checks of one suite. */
export class Suite {
    constructor(name) {
        this.name = name;
        this.results = [];
    }

    /**
     * Runs one check. A thrown error fails only this check, so one broken feature does not hide
     * the state of the others.
     */
    async check(id, title, body) {
        const started = Date.now();
        try {
            await body();
            this.results.push({ suite: this.name, id, title, ok: true, ms: Date.now() - started });
        } catch (error) {
            this.results.push({
                suite: this.name,
                id,
                title,
                ok: false,
                detail: redact(error instanceof CheckFailure ? error.message : `${error.name}: ${error.message}`),
                ms: Date.now() - started
            });
        }
    }
}

/** Prints a pass/fail table and returns the number of failures. */
export function printTable(results) {
    let failures = 0;
    let currentSuite;
    for (const result of results) {
        if (result.suite !== currentSuite) {
            currentSuite = result.suite;
            console.log(`\n${currentSuite.toUpperCase()}`);
        }
        const mark = result.ok ? 'PASS' : 'FAIL';
        console.log(`  ${mark}  ${result.id.padEnd(4)} ${result.title}`);
        if (!result.ok) {
            failures++;
            console.log(`             ${String(result.detail).split('\n').join('\n             ')}`);
        }
    }
    const passed = results.length - failures;
    console.log(`\n${passed} passed, ${failures} failed, ${results.length} checks`);
    return failures;
}

/** Writes the results as JSON under e2e/results so two runs can be compared later. */
export function saveResults(results, meta) {
    mkdirSync(resultsDir, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const file = join(resultsDir, `${stamp}${meta.label ? `-${meta.label}` : ''}.json`);
    writeFileSync(file, JSON.stringify({ ...meta, finishedAt: new Date().toISOString(), results }, null, 2));
    return file;
}
