const empApi = {
    subscribe: jest.fn().mockResolvedValue({ id: 'sub1' }),
    unsubscribe: jest.fn().mockResolvedValue({}),
    onError: jest.fn(),
    isEmpEnabled: true
};
export default empApi;
