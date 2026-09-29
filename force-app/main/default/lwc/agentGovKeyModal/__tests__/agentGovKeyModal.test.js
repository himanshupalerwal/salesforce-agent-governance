import { createElement } from 'lwc';
import AgentGovKeyModal from 'c/agentGovKeyModal';

const SECRET = 'agk_0123456789abcdef0123456789abcdef';
const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-agent-gov-key-modal', () => {
    let writeText;

    beforeEach(() => {
        writeText = jest.fn(() => Promise.resolve());
        Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true });
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    function mount() {
        const element = createElement('c-agent-gov-key-modal', { is: AgentGovKeyModal });
        element.agentName = 'Order Sync Agent';
        element.apiKey = SECRET;
        element.apiKeyPrefix = 'agk_01234567';
        document.body.appendChild(element);
        return element;
    }

    it('shows the key once with a warning, and never reads it back from the element', async () => {
        const element = mount();
        await flushPromises();

        expect(element.shadowRoot.querySelector('.key-warning').textContent).toBe(
            'Copy this key now. It will not be shown again.'
        );
        expect(element.shadowRoot.querySelector('.key-input').value).toBe(SECRET);
        expect(element.shadowRoot.textContent).toContain('Order Sync Agent');
        expect(element.apiKey).toBeUndefined();
    });

    it('copies the key and says so in a polite live region', async () => {
        const element = mount();
        await flushPromises();

        element.shadowRoot.querySelector('.copy-button').click();
        await flushPromises();

        expect(writeText).toHaveBeenCalledWith(SECRET);
        const status = element.shadowRoot.querySelector('.copy-status');
        expect(status.getAttribute('aria-live')).toBe('polite');
        expect(status.textContent).toBe('Copied to the clipboard.');
    });

    it('selects the key for manual copying when the clipboard is blocked', async () => {
        writeText.mockRejectedValue(new Error('blocked'));
        const element = mount();
        await flushPromises();
        const input = element.shadowRoot.querySelector('.key-input');
        const select = jest.spyOn(input, 'select');

        element.shadowRoot.querySelector('.copy-button').click();
        await flushPromises();

        expect(select).toHaveBeenCalled();
        expect(element.shadowRoot.querySelector('.copy-status').textContent).toContain('The key is selected');

        // Focusing the field selects the whole key, so it can be copied in one step.
        select.mockClear();
        input.dispatchEvent(new CustomEvent('focus'));
        expect(select).toHaveBeenCalledTimes(1);
    });

    it('clears the key when Done closes the dialog', async () => {
        const element = mount();
        await flushPromises();
        const closed = jest.fn();
        element.addEventListener('close', closed);
        const input = element.shadowRoot.querySelector('.key-input');

        element.shadowRoot.querySelector('.done-button').click();
        await flushPromises();

        expect(closed).toHaveBeenCalledTimes(1);
        expect(closed.mock.calls[0][0].detail).toBe('done');
        expect(input.value).toBe('');
        expect(element.shadowRoot.querySelector('.key-input')).toBeNull();
        expect(element.shadowRoot.textContent).not.toContain(SECRET);
    });

    it('clears the key when the dialog is dismissed another way', async () => {
        const element = mount();
        await flushPromises();
        const input = element.shadowRoot.querySelector('.key-input');

        document.body.removeChild(element);

        expect(input.value).toBe('');
    });
});
