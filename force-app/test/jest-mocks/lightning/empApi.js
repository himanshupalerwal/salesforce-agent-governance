/**
 * Jest mock for lightning/empApi. Mirrors the module's named exports so components can
 * import { subscribe, unsubscribe, onError, isEmpEnabled } exactly as they do at runtime.
 */
export const subscribe = jest.fn((channel) => Promise.resolve({ id: `subscription-${channel}`, channel }));
export const unsubscribe = jest.fn((subscription) => Promise.resolve(subscription));
export const onError = jest.fn();
export const isEmpEnabled = jest.fn(() => Promise.resolve(true));
export const setDebugFlag = jest.fn();
