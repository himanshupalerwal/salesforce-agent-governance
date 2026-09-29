/**
 * The actions an operator takes on agents from the AgentGov console: reset a circuit breaker,
 * activate, deactivate, rotate the API key, credit today's budget, and end a live session.
 * Every component that offers these actions runs them through this module, so the confirmation
 * wording, the permission checks, and the way outcomes are reported are the same everywhere.
 *
 * The custom permissions only decide which controls are shown. AgentGovAdminController checks
 * them again on the server, which remains the authority. This is a service module with no
 * template.
 */
import LightningConfirm from 'lightning/confirm';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import hasOperatePermission from '@salesforce/customPermission/AgentGov_Operate_Agents';
import hasManageKeysPermission from '@salesforce/customPermission/AgentGov_Manage_Keys';
import resetBreakers from '@salesforce/apex/AgentGovAdminController.resetBreakers';
import activateAgents from '@salesforce/apex/AgentGovAdminController.activateAgents';
import deactivateAgents from '@salesforce/apex/AgentGovAdminController.deactivateAgents';
import endSessions from '@salesforce/apex/AgentGovAdminController.endSessions';
import rotateApiKey from '@salesforce/apex/AgentGovAdminController.rotateApiKey';
import AgentGovKeyModal from 'c/agentGovKeyModal';
import AgentGovCreditModal from 'c/agentGovCreditModal';
import { describeError } from 'c/agentGovUtils';

export const canOperate = hasOperatePermission === true;
export const canManageKeys = hasManageKeysPermission === true;

// The server refuses larger selections; checking first gives a clearer message.
export const MAX_SELECTION = 200;

const MAX_FAILURES_LISTED = 3;

function agentCount(count) {
    return count === 1 ? '1 agent' : `${count} agents`;
}

function nameList(agents) {
    return agents.length === 1 ? agents[0].name : agentCount(agents.length);
}

// Each action: the label on its button or menu item, the label for several agents, who may use
// it, which agents it applies to, the confirmation when it is disruptive, and how it runs.
const ACTIONS = {
    reset: {
        label: 'Reset breaker',
        bulkLabel: 'Reset breakers',
        permitted: () => canOperate,
        appliesTo: (agent) => !!agent.breakerState && agent.breakerState !== 'CLOSED',
        confirm: (agents) => ({
            label: agents.length === 1 ? 'Reset circuit breaker?' : 'Reset circuit breakers?',
            message: `${nameList(agents)} will accept requests again right away. Reset a breaker once the cause of the failures is fixed.`,
            theme: 'warning'
        }),
        run: (agents) => resetBreakers({ registrationIds: agents.map((agent) => agent.id) }),
        doneTitle: 'Circuit breaker reset',
        failedTitle: 'Circuit breaker not reset'
    },
    activate: {
        label: 'Activate',
        bulkLabel: 'Activate',
        permitted: () => canOperate,
        appliesTo: (agent) => agent.status !== 'Active',
        run: (agents) => activateAgents({ registrationIds: agents.map((agent) => agent.id) }),
        doneTitle: 'Agent activated',
        failedTitle: 'Agent not activated'
    },
    deactivate: {
        label: 'Deactivate',
        bulkLabel: 'Deactivate',
        permitted: () => canOperate,
        appliesTo: (agent) => agent.status !== 'Inactive',
        confirm: (agents) => ({
            label: agents.length === 1 ? 'Deactivate agent?' : 'Deactivate agents?',
            message: `${nameList(agents)} will be refused on every entry point, and live sessions end, until activated again.`,
            theme: 'warning'
        }),
        run: (agents) => deactivateAgents({ registrationIds: agents.map((agent) => agent.id) }),
        doneTitle: 'Agent deactivated',
        failedTitle: 'Agent not deactivated'
    },
    rotateKey: {
        label: 'Rotate key',
        single: true,
        permitted: () => canManageKeys,
        appliesTo: () => true,
        confirm: (agents) => ({
            label: 'Replace API key?',
            message: `The current key for ${agents[0].name} stops working immediately. Every integration that uses it needs the new key.`,
            theme: 'warning'
        }),
        perform: rotateKey
    },
    credit: {
        label: 'Credit budget',
        single: true,
        permitted: () => canOperate,
        appliesTo: (agent) => !!agent.budgetStatus,
        perform: creditBudget
    },
    endSession: {
        label: 'End session',
        bulkLabel: 'End sessions',
        permitted: () => canOperate,
        appliesTo: (agent) => !!agent.liveSessionId,
        confirm: (agents) => ({
            label: 'End session?',
            message: `The live session of ${nameList(agents)} ends. The agent keeps working, and its next request starts a new session.`,
            theme: 'warning'
        }),
        run: (agents) => endSessions({ sessionIds: agents.map((agent) => agent.liveSessionId) }),
        outcomeKey: 'liveSessionId',
        doneTitle: 'Session ended',
        failedTitle: 'Session not ended'
    }
};

const ACTION_ORDER = ['reset', 'activate', 'deactivate', 'credit', 'rotateKey', 'endSession'];

function toast(host, title, message, variant) {
    host.dispatchEvent(new ShowToastEvent({ title, message, variant }));
}

/**
 * The label of an action.
 * @param {string} name
 * @param {{bulk?: boolean}} [options] The label for several agents
 * @returns {string}
 */
export function actionLabel(name, { bulk = false } = {}) {
    const action = ACTIONS[name];
    return bulk ? action.bulkLabel : action.label;
}

/**
 * Whether the viewer may use an action at all.
 * @param {string} name
 * @returns {boolean}
 */
export function isPermitted(name) {
    return !!ACTIONS[name] && ACTIONS[name].permitted();
}

/**
 * The agents an action would change, from a selection.
 * @param {string} name
 * @param {Object[]} agents Agent summaries
 * @returns {Object[]}
 */
export function eligibleAgents(name, agents) {
    const action = ACTIONS[name];
    return (agents || []).filter((agent) => action.appliesTo(agent));
}

/**
 * The actions the viewer may take on one agent in its current state, in display order.
 * @param {Object} agent An agent summary
 * @param {{exclude?: string[]}} [options] Actions not to offer, for example ones shown elsewhere
 * @returns {{name: string, label: string}[]}
 */
export function actionsFor(agent, { exclude = [] } = {}) {
    return ACTION_ORDER.filter(
        (name) => !exclude.includes(name) && ACTIONS[name].permitted() && ACTIONS[name].appliesTo(agent)
    ).map((name) => ({ name, label: ACTIONS[name].label }));
}

/**
 * Builds the toast for a set of per-record outcomes.
 * @param {Object} action
 * @param {Object[]} agents The agents the action was run on
 * @param {{recordId: string, success: boolean, message: string}[]} outcomes
 * @returns {{title: string, message: string, variant: string, succeeded: number}}
 */
function summarize(action, agents, outcomes) {
    const key = action.outcomeKey || 'id';
    const byRecord = new Map(agents.map((agent) => [agent[key], agent]));
    const results = outcomes || [];
    const succeeded = results.filter((outcome) => outcome.success);
    const failed = results.filter((outcome) => !outcome.success);
    const nameOf = (outcome) => (byRecord.get(outcome.recordId) || { name: 'An agent' }).name;
    if (agents.length === 1 && results.length === 1) {
        const [outcome] = results;
        return {
            title: outcome.success ? action.doneTitle : action.failedTitle,
            message: `${agents[0].name}: ${outcome.message}`,
            variant: outcome.success ? 'success' : 'error',
            succeeded: succeeded.length
        };
    }
    const parts = [`${action.bulkLabel}: ${succeeded.length} of ${agentCount(results.length)} done.`];
    if (failed.length) {
        const listed = failed
            .slice(0, MAX_FAILURES_LISTED)
            .map((outcome) => `${nameOf(outcome)} (${outcome.message})`)
            .join('; ');
        const more = failed.length > MAX_FAILURES_LISTED ? ` and ${failed.length - MAX_FAILURES_LISTED} more` : '';
        parts.push(`Not done: ${listed}${more}.`);
    }
    let variant = 'success';
    if (failed.length) {
        variant = succeeded.length ? 'warning' : 'error';
    }
    return { title: action.bulkLabel, message: parts.join(' '), variant, succeeded: succeeded.length };
}

async function rotateKey(host, [agent]) {
    let issued = await rotateApiKey({ registrationId: agent.id });
    if (!issued || !issued.success) {
        const message = `${agent.name}: ${issued ? issued.message : 'The API key could not be replaced.'}`;
        toast(host, 'API key not replaced', message, 'error');
        return { changed: false, message };
    }
    const prefix = issued.apiKeyPrefix;
    try {
        await AgentGovKeyModal.open({
            size: 'small',
            label: 'New API key',
            description: `The new API key for ${agent.name}. It is shown once.`,
            agentName: agent.name,
            apiKey: issued.apiKey,
            apiKeyPrefix: prefix
        });
    } finally {
        // The key is shown once and never stored. Dropping this reference leaves the dialog as
        // its only holder, and the dialog clears its copy when it closes.
        issued = null;
    }
    const message = `${agent.name}: the API key was replaced. The new key starts with ${prefix}.`;
    toast(host, 'API key replaced', message, 'success');
    return { changed: true, message };
}

async function creditBudget(host, [agent]) {
    const outcome = await AgentGovCreditModal.open({
        size: 'small',
        label: 'Credit budget',
        description: `Credit usage back to today's budget for ${agent.name}.`,
        registrationId: agent.id,
        agentName: agent.name
    });
    if (!outcome || !outcome.success) {
        return { changed: false, cancelled: true, message: '' };
    }
    const message = `${agent.name}: ${outcome.message}`;
    toast(host, 'Budget credited', message, 'success');
    return { changed: true, message };
}

/**
 * Runs an action on one or more agents: asks for confirmation when the action is disruptive,
 * calls the server, and reports the outcome in a toast. The agents it does not apply to, for
 * example agents already active, are left out.
 * @param {HTMLElement} host The component that dispatches the toast
 * @param {string} name The action
 * @param {Object[]} agents Agent summaries: id, name, and the state fields the action needs
 * @returns {Promise<{changed: boolean, cancelled?: boolean, message: string}>} changed is true
 *          when anything changed, so the caller knows to refresh; message is for its live region
 */
export async function runAgentAction(host, name, agents) {
    const action = ACTIONS[name];
    if (!action || !action.permitted()) {
        return { changed: false, message: '' };
    }
    const targets = eligibleAgents(name, agents);
    if (!targets.length) {
        const message = `${action.label}: nothing to change for the selected agents.`;
        toast(host, action.label, message, 'info');
        return { changed: false, message };
    }
    if (targets.length > MAX_SELECTION) {
        const message = `Select at most ${MAX_SELECTION} agents for one action.`;
        toast(host, action.label, message, 'error');
        return { changed: false, message };
    }
    const subjects = action.single ? targets.slice(0, 1) : targets;
    if (action.confirm) {
        const confirmed = await LightningConfirm.open(action.confirm(subjects));
        if (!confirmed) {
            return { changed: false, cancelled: true, message: '' };
        }
    }
    try {
        if (action.perform) {
            return await action.perform(host, subjects);
        }
        const summary = summarize(action, subjects, await action.run(subjects));
        toast(host, summary.title, summary.message, summary.variant);
        return { changed: summary.succeeded > 0, message: summary.message };
    } catch (error) {
        const message = describeError(error);
        toast(host, action.failedTitle || `${action.label} failed`, message, 'error');
        return { changed: false, message };
    }
}
