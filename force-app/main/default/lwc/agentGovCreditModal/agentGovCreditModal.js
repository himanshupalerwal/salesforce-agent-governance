/**
 * Credits usage back to an agent's budget for today, the current day in the org's time zone,
 * for example after an incident is resolved. The person picks the limit type and the number of
 * units; the server never takes usage below zero and re-evaluates the budget status from the
 * corrected usage. The dialog closes with the server's outcome, which says how much was
 * credited, when the credit succeeds, and stays open with the reason when it does not.
 */
import { api } from 'lwc';
import LightningModal from 'lightning/modal';
import creditBudget from '@salesforce/apex/AgentGovAdminController.creditBudget';
import { describeError } from 'c/agentGovUtils';

const LIMIT_OPTIONS = [
    { label: 'API calls', value: 'API_Calls' },
    { label: 'SOQL queries', value: 'SOQL_Queries' },
    { label: 'DML operations', value: 'DML_Operations' }
];
const AMOUNT_MESSAGE = 'Enter a whole number of at least 1.';

export default class AgentGovCreditModal extends LightningModal {
    /**
     * Id of the agent registration whose budget is credited.
     * @type {string}
     */
    @api registrationId;

    /**
     * Name of the agent, shown in the dialog.
     * @type {string}
     */
    @api agentName;

    limitOptions = LIMIT_OPTIONS;
    limitType = LIMIT_OPTIONS[0].value;
    amount = '';
    saving = false;
    errorMessage = '';

    handleLimitChange(event) {
        this.limitType = event.detail.value;
    }

    handleAmountChange(event) {
        this.amount = event.detail.value;
        this.errorMessage = '';
    }

    handleCancel() {
        this.close();
    }

    async handleSubmit() {
        const amount = Number(this.amount);
        const amountInput = this.refs ? this.refs.amountInput : undefined;
        const amountValid = this.amount !== '' && Number.isInteger(amount) && amount >= 1;
        if (amountInput) {
            amountInput.setCustomValidity(amountValid ? '' : AMOUNT_MESSAGE);
            amountInput.reportValidity();
        }
        if (!amountValid) {
            this.errorMessage = AMOUNT_MESSAGE;
            return;
        }
        this.errorMessage = '';
        this.saving = true;
        // The dialog must not close while the credit is being applied, or its result is lost.
        this.disableClose = true;
        let outcome;
        try {
            outcome = await creditBudget({
                registrationId: this.registrationId,
                limitType: this.limitType,
                amount
            });
        } catch (error) {
            this.errorMessage = describeError(error);
        } finally {
            this.saving = false;
            this.disableClose = false;
        }
        if (outcome && outcome.success) {
            this.close(outcome);
        } else if (outcome) {
            this.errorMessage = outcome.message || 'The budget could not be credited.';
        }
    }
}
