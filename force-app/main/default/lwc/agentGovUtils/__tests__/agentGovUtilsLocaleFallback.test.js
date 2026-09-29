import { formatDateTime, formatNumber } from 'c/agentGovUtils';

jest.mock('@salesforce/i18n/locale', () => ({ default: 'not a locale!' }), { virtual: true });
jest.mock('@salesforce/i18n/timeZone', () => ({ default: 'Mars/Olympus_Mons' }), { virtual: true });

describe('agentGovUtils formatting with settings Intl does not know', () => {
    it('falls back instead of failing, so dates and numbers still show', () => {
        expect(formatDateTime('2026-09-15T10:00:00.000Z')).toMatch(/2026/);
        expect(formatNumber(12345)).toMatch(/12.?345/);
    });
});
