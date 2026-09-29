/**
 * Jest mock for lightning/confirm. The stub in sfdx-lwc-jest throws from open(); this one
 * resolves to true, as if the person chose OK. Specs that need Cancel use
 * LightningConfirm.open.mockResolvedValueOnce(false).
 */
export default class LightningConfirm {
    static open = jest.fn(() => Promise.resolve(true));
}
