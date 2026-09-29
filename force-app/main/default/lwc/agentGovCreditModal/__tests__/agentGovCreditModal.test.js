import { createElement } from 'lwc';
import AgentGovCreditModal from 'c/agentGovCreditModal';
import creditBudget from '@salesforce/apex/AgentGovAdminController.creditBudget';

jest.mock('@salesforce/apex/AgentGovAdminController.creditBudget', () => ({ default: jest.fn() }), {
    virtual: true
});

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-agent-gov-credit-modal', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function mount() {
        const element = createElement('c-agent-gov-credit-modal', { is: AgentGovCreditModal });
        element.registrationId = 'a1';
        element.agentName = 'Case Triage Agent';
        document.body.appendChild(element);
        const closed = jest.fn();
        element.addEventListener('close', closed);
        return { element, closed };
    }

    function setAmount(element, value) {
        const input = element.shadowRoot.querySelector('lightning-input');
        input.setCustomValidity = jest.fn();
        input.reportValidity = jest.fn();
        input.dispatchEvent(new CustomEvent('change', { detail: { value } }));
        return input;
    }

    it('credits the chosen limit and closes with the outcome', async () => {
        const outcome = { recordId: 'a1', success: true, message: "Credited 50 SOQL queries to today's budget." };
        creditBudget.mockResolvedValue(outcome);
        const { element, closed } = mount();
        await flushPromises();

        const combobox = element.shadowRoot.querySelector('lightning-combobox');
        expect(combobox.options.map((option) => option.value)).toEqual(['API_Calls', 'SOQL_Queries', 'DML_Operations']);
        combobox.dispatchEvent(new CustomEvent('change', { detail: { value: 'SOQL_Queries' } }));
        const input = setAmount(element, '50');
        await flushPromises();

        element.shadowRoot.querySelector('.submit-button').click();
        await flushPromises();

        expect(input.setCustomValidity).toHaveBeenCalledWith('');
        expect(creditBudget).toHaveBeenCalledWith({ registrationId: 'a1', limitType: 'SOQL_Queries', amount: 50 });
        expect(closed.mock.calls[0][0].detail).toEqual(outcome);
    });

    it('asks for a whole number of at least 1 before calling the server', async () => {
        const { element, closed } = mount();
        await flushPromises();

        element.shadowRoot.querySelector('.submit-button').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('.error-message').textContent).toBe(
            'Enter a whole number of at least 1.'
        );

        const input = setAmount(element, '2.5');
        await flushPromises();
        element.shadowRoot.querySelector('.submit-button').click();
        await flushPromises();

        expect(input.setCustomValidity).toHaveBeenCalledWith('Enter a whole number of at least 1.');
        expect(creditBudget).not.toHaveBeenCalled();
        expect(closed).not.toHaveBeenCalled();
    });

    it('stays open with the reason when the credit fails', async () => {
        creditBudget.mockResolvedValueOnce({
            recordId: 'a1',
            success: false,
            message: 'The budget could not be credited.'
        });
        const { element, closed } = mount();
        await flushPromises();
        setAmount(element, '10');
        await flushPromises();

        element.shadowRoot.querySelector('.submit-button').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('.error-message').textContent).toBe(
            'The budget could not be credited.'
        );
        expect(closed).not.toHaveBeenCalled();

        creditBudget.mockResolvedValueOnce({ success: false });
        element.shadowRoot.querySelector('.submit-button').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('.error-message').textContent).toBe(
            'The budget could not be credited.'
        );

        creditBudget.mockRejectedValueOnce({ body: { message: 'Credit must be a whole number of at least 1.' } });
        element.shadowRoot.querySelector('.submit-button').click();
        await flushPromises();
        expect(element.shadowRoot.querySelector('.error-message').textContent).toBe(
            'Credit must be a whole number of at least 1.'
        );
        expect(element.shadowRoot.querySelector('.submit-button').disabled).toBe(false);
    });

    it('closes without a result when cancelled', async () => {
        const { element, closed } = mount();
        await flushPromises();
        element.shadowRoot.querySelector('.cancel-button').click();
        expect(closed).toHaveBeenCalledTimes(1);
        expect(closed.mock.calls[0][0].detail).toBeFalsy();
    });
});
