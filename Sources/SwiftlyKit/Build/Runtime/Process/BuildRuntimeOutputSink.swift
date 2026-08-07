actor BuildRuntimeOutputSink {
    
    let handler: BuildRuntimeOutputHandler?
    
    init(handler: BuildRuntimeOutputHandler?) {
        self.handler = handler
    }
    
    func emit(_ stream: BuildRuntimeOutputStream, _ text: String) async {
        await handler?(stream, text)
    }
    
}
