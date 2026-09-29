/**
 * Jest mock for lightning/modal. sfdx-lwc-jest ships no stub for the LightningModal base class.
 * This one mirrors what the AgentGov dialogs use: the static open() that callers await, and
 * close(result), which here dispatches a 'close' event carrying the result so specs can observe
 * it. disableClose is a plain property, as a dialog sets it on itself while it saves.
 */
import { LightningElement } from 'lwc';

export default class LightningModal extends LightningElement {
    static open = jest.fn(() => Promise.resolve());

    disableClose = false;

    close(result) {
        this.dispatchEvent(new CustomEvent('close', { detail: result }));
    }
}
