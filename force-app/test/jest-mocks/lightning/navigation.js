export const NavigationMixin = (Base) => {
    return class extends Base {
        navigate() {}
        generateUrl() {
            return Promise.resolve('url');
        }
    };
};
export const Navigate = Symbol('Navigate');
export const GenerateUrl = Symbol('GenerateUrl');
