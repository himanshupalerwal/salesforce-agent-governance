export const ShowToastEventName = 'lightning__showtoast';
export class ShowToastEvent extends CustomEvent {
    constructor(toast) {
        super('lightning__showtoast', { detail: toast });
    }
}
