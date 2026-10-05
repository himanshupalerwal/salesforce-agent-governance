/**
 * Salesforce CLI helpers for the end-to-end suite.
 *
 * Every API call is made by the CLI itself, mostly through `sf api request rest`, so access and
 * refresh tokens stay in the CLI's own credential store. From CLI 2.136.8 the JSON output the
 * harness reads holds no token (`sf org display` prints a placeholder instead) unless
 * SF_TEMP_SHOW_SECRETS is set, so the CLI runs here without that variable. The browser checks
 * are the exception to the CLI making every call: ui.mjs hands Chromium a single-use login URL
 * from `sf org open --url-only`, and Chromium then calls the org itself.
 */
import { execFile as execFileCallback, execFileSync } from 'node:child_process';
import { closeSync, mkdtempSync, openSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);
const MAX_BUFFER = 256 * 1024 * 1024;
// A request the org never answers, as can happen while it runs a long test job, fails after
// this long instead of stalling the whole run.
const REQUEST_TIMEOUT_MS = 3 * 60 * 1000;

// Commands whose JSON output can run to megabytes: a deploy's results and an anonymous Apex
// run's debug log. Neither returns a credential.
const LARGE_OUTPUT_COMMANDS = new Set(['project deploy', 'apex run']);

const CLI_ENV = { ...process.env };
delete CLI_ENV.SF_TEMP_SHOW_SECRETS;

/** Repository root, so commands such as a source deploy behave the same from any directory. */
export const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

export const API_VERSION = '67.0';

/**
 * Runs an sf command with --json and returns its raw JSON output. A deploy or an anonymous Apex
 * run writes to a temporary file, deleted once read: when a command fails, the CLI can exit
 * before a large result is fully written to a pipe, which cut deploy errors off at 8,192
 * characters. Every other command is read from a pipe, so what it returns, a login URL or a
 * generated password included, is never written to disk.
 * @param {string[]} args Command and flags, without --json
 * @param {string} cwd Directory to run in, which decides the SFDX project for source commands
 */
export function sfJsonText(args, cwd = REPO_ROOT) {
    const command = [...args, '--json'];
    const options = { cwd, env: CLI_ENV, maxBuffer: MAX_BUFFER };
    if (!LARGE_OUTPUT_COMMANDS.has(args.slice(0, 2).join(' '))) {
        try {
            return execFileSync('sf', command, { ...options, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
        } catch (error) {
            // A failed command still writes its JSON envelope, which the caller inspects.
            return error.stdout ?? '';
        }
    }
    const dir = mkdtempSync(join(tmpdir(), 'agentgov-sf-'));
    const outPath = join(dir, 'out.json');
    const fd = openSync(outPath, 'w');
    try {
        execFileSync('sf', command, { ...options, stdio: ['ignore', fd, 'pipe'] });
    } catch {
        // A failed command still writes its JSON envelope, which the caller inspects.
    } finally {
        closeSync(fd);
    }
    const out = readFileSync(outPath, 'utf8');
    rmSync(dir, { recursive: true, force: true });
    return out;
}

/**
 * Runs an sf command with --json and returns the parsed envelope.
 * @param {string[]} args Command and flags, without --json
 * @param {{ allowFail?: boolean }} options allowFail returns a failed envelope instead of throwing
 */
export function sf(args, { allowFail = false } = {}) {
    const out = sfJsonText(args);
    let json;
    try {
        json = JSON.parse(out || '{}');
    } catch {
        json = { status: 1, message: String(out).slice(-500) };
    }
    if (json.status !== 0 && !allowFail) {
        throw new Error(`sf ${args.slice(0, 3).join(' ')} failed: ${json.message ?? 'no message'}`);
    }
    return json;
}

/**
 * Parses the output of `sf api request rest --include`: a status line, header lines, then the
 * body. The CLI does not always print a blank line between headers and body, so the headers end
 * at the first line that is not a `name: value` pair.
 */
function parseIncludedResponse(stdout) {
    const text = stdout.replace(/\r\n/g, '\n');
    const start = text.search(/^HTTP\/[\d.]+ \d{3}/m);
    if (start < 0) {
        throw new Error(`Unrecognised response from sf api request rest: ${text.slice(0, 300)}`);
    }
    const [statusLine, ...lines] = text.slice(start).split('\n');
    const headers = {};
    let index = 0;
    for (; index < lines.length; index++) {
        const match = /^([A-Za-z0-9-]+):\s?(.*)$/.exec(lines[index]);
        if (!match) {
            break;
        }
        headers[match[1].toLowerCase()] = match[2].trim();
    }
    const rawBody = lines.slice(index).join('\n').trim();
    let body = rawBody;
    if (rawBody) {
        try {
            body = JSON.parse(rawBody);
        } catch {
            // Non-JSON bodies are returned as text.
        }
    }
    return { status: Number(statusLine.split(' ')[1]), headers, body };
}

/** One org, acting as one user, through the CLI. */
export class Org {
    /**
     * @param {string} targetOrg Alias or username the CLI is authenticated as
     */
    constructor(targetOrg) {
        this.targetOrg = targetOrg;
        this.describeCache = new Map();
    }

    /**
     * Sends an authenticated HTTP request.
     * @returns {Promise<{ status: number, headers: Record<string, string>, body: any }>}
     */
    async rest(method, path, { body, headers = {} } = {}) {
        const args = ['api', 'request', 'rest', path, '--method', method, '--include', '--target-org', this.targetOrg];
        for (const [name, value] of Object.entries(headers)) {
            args.push('--header', `${name}:${value}`);
        }
        if (body !== undefined) {
            args.push('--body', JSON.stringify(body));
        }
        let stdout;
        try {
            ({ stdout } = await execFile('sf', args, {
                cwd: REPO_ROOT,
                env: CLI_ENV,
                encoding: 'utf8',
                maxBuffer: MAX_BUFFER,
                timeout: REQUEST_TIMEOUT_MS
            }));
        } catch (error) {
            if (error.killed) {
                throw new Error(`sf api request rest ${method} got no answer within ${REQUEST_TIMEOUT_MS / 1000}s`);
            }
            // The CLI exits non-zero for some HTTP errors but still prints the response.
            stdout = error.stdout ?? '';
            if (!stdout.includes('HTTP/')) {
                throw new Error(`sf api request rest ${method} ${path} failed: ${error.stderr || error.message}`);
            }
        }
        return parseIncludedResponse(stdout);
    }

    /** Calls an Apex REST endpoint, for example apexRest('POST', '/agentgov/authorize', ...). */
    apexRest(method, path, options) {
        return this.rest(method, `/services/apexrest${path}`, options);
    }

    /** Runs a SOQL query and returns its records. */
    async query(soql) {
        const response = await this.rest('GET', `/services/data/v${API_VERSION}/query?q=${encodeURIComponent(soql)}`);
        if (response.status !== 200) {
            const detail = Array.isArray(response.body) ? response.body[0]?.message : JSON.stringify(response.body);
            throw new Error(`Query failed (${response.status}): ${detail}`);
        }
        return response.body.records;
    }

    /** Runs anonymous Apex as this user and throws with the platform's message if it fails. */
    async apex(code) {
        const response = await this.rest(
            'GET',
            `/services/data/v${API_VERSION}/tooling/executeAnonymous/?anonymousBody=${encodeURIComponent(code)}`
        );
        const result = response.body;
        if (response.status !== 200 || !result) {
            throw new Error(`Anonymous Apex request failed (${response.status}): ${JSON.stringify(result)}`);
        }
        if (!result.compiled) {
            throw new Error(`Apex did not compile: ${result.compileProblem} (line ${result.line})`);
        }
        if (!result.success) {
            throw new Error(`Apex failed: ${result.exceptionMessage}`);
        }
        return result;
    }

    /** Invokes an invocable Apex action the way a Flow or an external caller would. */
    action(className, inputs) {
        return this.rest('POST', `/services/data/v${API_VERSION}/actions/custom/apex/${className}`, {
            body: { inputs }
        });
    }

    /** Returns the set of field API names on an object, so checks can tell a missing field from a wrong value. */
    async fieldNames(sobjectName) {
        if (!this.describeCache.has(sobjectName)) {
            const response = await this.rest('GET', `/services/data/v${API_VERSION}/sobjects/${sobjectName}/describe`);
            if (response.status !== 200) {
                throw new Error(`Describe of ${sobjectName} failed (${response.status})`);
            }
            this.describeCache.set(sobjectName, new Set(response.body.fields.map((field) => field.name)));
        }
        return this.describeCache.get(sobjectName);
    }
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Polls until the probe returns a truthy value or the timeout passes. Platform events and batch
 * jobs complete asynchronously, so checks on their side effects have to wait for them.
 * @returns The probe's last value
 */
export async function waitFor(probe, { timeoutMs = 60000, intervalMs = 3000 } = {}) {
    const deadline = Date.now() + timeoutMs;
    let last = await probe();
    while (!last && Date.now() < deadline) {
        await sleep(intervalMs);
        last = await probe();
    }
    return last;
}

/** Quotes a value for use inside a SOQL or Apex string literal. */
export function quote(value) {
    return `'${String(value).replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;
}
