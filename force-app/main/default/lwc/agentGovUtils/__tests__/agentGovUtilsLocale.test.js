import { formatDateTime, formatTime, formatDate, formatNumber } from 'c/agentGovUtils';

jest.mock('@salesforce/i18n/locale', () => ({ default: 'de-DE' }), { virtual: true });
jest.mock('@salesforce/i18n/timeZone', () => ({ default: 'Europe/Berlin' }), { virtual: true });

describe('agentGovUtils formatting for a German user in Berlin', () => {
    it("uses the user's Salesforce locale and time zone, not the browser's", () => {
        // 10:00 UTC is 12:00 in Berlin in September.
        expect(formatDateTime('2026-09-15T10:00:00.000Z')).toBe('15.09.2026, 12:00');
        expect(formatDateTime('2026-09-15T10:00:05.000Z', { seconds: true })).toBe('15.09.2026, 12:00:05');
        expect(formatTime('2026-09-15T10:00:00.000Z')).toBe('12:00');
        expect(formatDate('2026-09-15')).toBe('Di., 15. Sept.');
        expect(formatNumber(12345)).toBe('12.345');
    });
});
