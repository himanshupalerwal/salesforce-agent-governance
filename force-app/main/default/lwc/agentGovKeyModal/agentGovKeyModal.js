/**
 * Shows a newly issued API key once, with a copy button and a warning that it will not be
 * shown again. The server stores only the key's hash, so this dialog is the only place the key
 * ever appears. The component holds the key only while the dialog is open: closing it, by the
 * Done button, the close button, or Escape, clears the key.
 */
import { api } from 'lwc';
import LightningModal from 'lightning/modal';

export default class AgentGovKeyModal extends LightningModal {
    /**
     * Name of the agent whose key was replaced, shown in the dialog.
     * @type {string}
     */
    @api agentName;

    key;
    copyStatus = '';

    /**
     * The newly issued key. Write-only: reading the property returns nothing, so the key cannot
     * be read back from the element once it has been handed over.
     * @type {string}
     */
    @api
    get apiKey() {
        return undefined;
    }
    set apiKey(value) {
        this.key = value;
    }

    get hasKey() {
        return !!this.key;
    }

    async handleCopy() {
        try {
            await navigator.clipboard.writeText(this.key);
            this.copyStatus = 'Copied to the clipboard.';
        } catch {
            // Some browsers and security settings block scripted clipboard access. Selecting the
            // text still lets the person copy it with the keyboard.
            this.selectKey();
            this.copyStatus = 'Copying is blocked here. The key is selected: press Ctrl+C, or Command+C on a Mac.';
        }
    }

    handleKeyFocus(event) {
        event.target.select();
    }

    handleDone() {
        this.clearKey();
        this.close('done');
    }

    disconnectedCallback() {
        this.clearKey();
    }

    selectKey() {
        const input = this.refs ? this.refs.keyInput : undefined;
        if (input) {
            input.focus();
            input.select();
        }
    }

    clearKey() {
        const input = this.refs ? this.refs.keyInput : undefined;
        if (input) {
            input.value = '';
        }
        this.key = undefined;
        this.copyStatus = '';
    }
}
