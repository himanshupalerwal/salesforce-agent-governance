/**
 * The AgentGov console: one page with Overview, Agents, Activity, and Conflicts tabs, and a Setup
 * tab for people who hold the AgentGov_Operate_Agents custom permission. The console owns the
 * drill-down state: selecting a key figure on the overview opens the tab and agent filter it
 * names, and moves focus to that tab's content. Each tab is its own component, which reads and
 * acts through the AgentGov controllers.
 */
import { LightningElement } from 'lwc';
import { listenToAgentGovEvents } from 'c/agentGovUtils';
import { canOperate } from 'c/agentGovAdminActions';

const TABS = ['overview', 'agents', 'activity', 'conflicts', 'setup'];
const AGENT_FILTER_LABELS = {
    all: 'all agents',
    attention: 'agents that need attention',
    tripped: 'agents with a tripped circuit breaker',
    active: 'active agents',
    inactive: 'inactive agents'
};

export default class AgentGovConsole extends LightningElement {
    activeTab = 'overview';
    agentFilter = 'all';
    agentsFocusRequest = 0;
    activityFocusRequest = 0;
    // Unknown until the event connection reports, so the page never claims updates are off
    // while it is still connecting.
    liveUpdates;
    announcement = '';

    connectedCallback() {
        // Each tab refreshes itself; the console only shows whether updates are arriving.
        this.releaseEvents = listenToAgentGovEvents(
            () => {},
            (live) => {
                this.liveUpdates = live;
            }
        );
    }

    disconnectedCallback() {
        if (this.releaseEvents) {
            this.releaseEvents();
            this.releaseEvents = undefined;
        }
    }

    get showSetup() {
        return canOperate;
    }

    get liveUpdatesLabel() {
        if (this.liveUpdates === undefined) {
            return 'Connecting…';
        }
        return this.liveUpdates ? 'Live' : 'Live updates off';
    }

    get liveUpdatesTitle() {
        if (this.liveUpdates === undefined) {
            return 'Connecting to live updates';
        }
        return this.liveUpdates ? 'Changes appear as agents act' : 'Use Refresh to see the latest changes';
    }

    get liveStatusClass() {
        return `ag-meta ag-live live-status${this.liveUpdates ? ' ag-live_on' : ''}`;
    }

    handleTabActive(event) {
        this.activeTab = event.target.value;
    }

    handleDrilldown(event) {
        const { tab, filter } = event.detail || {};
        if (!TABS.includes(tab) || (tab === 'setup' && !canOperate)) {
            return;
        }
        if (tab === 'agents') {
            this.agentFilter = AGENT_FILTER_LABELS[filter] ? filter : 'all';
            this.agentsFocusRequest += 1;
            this.announcement = `Agents tab, showing ${AGENT_FILTER_LABELS[this.agentFilter]}.`;
        } else {
            if (tab === 'activity') {
                this.activityFocusRequest += 1;
            }
            this.announcement = `${tab.charAt(0).toUpperCase()}${tab.slice(1)} tab.`;
        }
        this.activeTab = tab;
    }

    handleFilterChange(event) {
        this.agentFilter = event.detail.filter;
    }
}
