struct MicrophoneErrorInfo {
    let code: String
    let message: String
    /// True when the recording has stopped and the caller must reconnect to resume.
    let isFatal: Bool
    /// True only for INTERRUPTED — the library will reinstall the tap automatically.
    let autoResuming: Bool
}

protocol MicrophoneDataDelegate: AnyObject {
    func onMicrophoneData(_ microphoneData: Data, _ soundLevel: Float?, _ frequencyBands: FrequencyBands?)
    func onMicrophoneError(_ error: MicrophoneErrorInfo)
}
