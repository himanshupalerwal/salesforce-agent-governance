/**
 * Jest mock for lightning/navigation. Mirrors the platform API, where Navigate and GenerateUrl
 * are symbols on NavigationMixin, and records the last page reference so specs can assert
 * where a component navigated.
 */
import { createTestWireAdapter } from '@salesforce/wire-service-jest-util';

export const CurrentPageReference = createTestWireAdapter(jest.fn());

export const Navigate = Symbol('Navigate');
export const GenerateUrl = Symbol('GenerateUrl');

let lastNavigation = {};

export const NavigationMixin = (Base) => {
    return class extends Base {
        [Navigate](pageReference, replace) {
            lastNavigation = { pageReference, replace };
        }
        [GenerateUrl]() {
            return Promise.resolve('url');
        }
        navigate() {}
        generateUrl() {
            return Promise.resolve('url');
        }
    };
};
NavigationMixin.Navigate = Navigate;
NavigationMixin.GenerateUrl = GenerateUrl;

/**
 * @returns {{pageReference: Object, replace: boolean}} The arguments of the last navigation
 */
export const getNavigateCalledWith = () => lastNavigation;

/** Forgets the last navigation, for use between specs. */
export const resetNavigation = () => {
    lastNavigation = {};
};
