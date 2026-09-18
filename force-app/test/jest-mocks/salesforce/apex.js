/**
 * Jest mock for @salesforce/apex. refreshApex is a spy that resolves immediately so tests
 * can assert how many wires a component refreshes.
 */
export const refreshApex = jest.fn(() => Promise.resolve());
export const getSObjectValue = jest.fn((sobject, fieldApiName) => (sobject ? sobject[fieldApiName] : undefined));
