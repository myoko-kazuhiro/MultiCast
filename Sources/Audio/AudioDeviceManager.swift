import Foundation
import CoreAudio
import os.log

/// Core Audio HAL APIを使用してシステムのオーディオデバイスを管理する
class AudioDeviceManager: ObservableObject {
    static let shared = AudioDeviceManager()
    
    private let logger = AppLogger(category: "AudioDeviceManager")
    
    /// 利用可能な全デバイス
    @Published private(set) var allDevices: [AudioDevice] = []
    
    /// 入力デバイス一覧
    @Published private(set) var inputDevices: [AudioDevice] = []
    
    /// 出力デバイス一覧
    @Published private(set) var outputDevices: [AudioDevice] = []
    
    /// デフォルト入力デバイス
    @Published private(set) var defaultInputDevice: AudioDevice?
    
    /// デフォルト出力デバイス
    @Published private(set) var defaultOutputDevice: AudioDevice?
    
    private init() {
        refreshDevices()
    }
    
    // MARK: - Device Enumeration
    
    /// デバイス一覧を再取得
    @discardableResult
    func refreshDevices() -> [AudioDevice] {
        let deviceIDs = getAllDeviceIDs()
        let devices = deviceIDs.compactMap { createAudioDevice(from: $0) }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.allDevices = devices
            self.inputDevices = devices.filter { $0.isInput }
            self.outputDevices = devices.filter { $0.isOutput }
            self.defaultInputDevice = self.getDefaultDevice(for: .input)
            self.defaultOutputDevice = self.getDefaultDevice(for: .output)
        }
        
        logger.info("Refreshed devices: \(devices.count) total, \(devices.filter { $0.isInput }.count) inputs, \(devices.filter { $0.isOutput }.count) outputs")
        
        return devices
    }
    
    /// 全デバイスのAudioDeviceIDを取得
    private func getAllDeviceIDs() -> [AudioDeviceID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard status == noErr else {
            logger.error("Failed to get device list size: \(status)")
            return []
        }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        
        guard getStatus == noErr else {
            logger.error("Failed to get device list: \(getStatus)")
            return []
        }
        
        return deviceIDs
    }
    
    /// AudioDeviceIDからAudioDeviceモデルを生成
    private func createAudioDevice(from deviceID: AudioDeviceID) -> AudioDevice? {
        guard let name = getDeviceName(deviceID) else { return nil }
        let uid = getDeviceUID(deviceID) ?? ""
        let manufacturer = getDeviceManufacturer(deviceID) ?? ""
        let inputChannels = getChannelCount(deviceID, scope: kAudioDevicePropertyScopeInput)
        let outputChannels = getChannelCount(deviceID, scope: kAudioDevicePropertyScopeOutput)
        let sampleRate = getDeviceSampleRate(deviceID)
        
        return AudioDevice(
            id: deviceID,
            uid: uid,
            name: name,
            manufacturer: manufacturer,
            inputChannelCount: inputChannels,
            outputChannelCount: outputChannels,
            sampleRate: sampleRate
        )
    }
    
    // MARK: - Device Properties
    
    /// デバイス名を取得
    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        return getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    }
    
    /// デバイスUIDを取得
    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        return getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }
    
    /// メーカー名を取得
    private func getDeviceManufacturer(_ deviceID: AudioDeviceID) -> String? {
        return getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceManufacturerCFString)
    }
    
    /// チャンネル数を取得
    private func getChannelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }
        
        // AudioBufferList は可変長構造体のため、CoreAudio が必要とするサイズ分のメモリを確保する
        let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPointer.deallocate() }
        
        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        
        let getStatus = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer)
        guard getStatus == noErr else { return 0 }
        
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        var channelCount = 0
        for buffer in bufferList {
            channelCount += Int(buffer.mNumberChannels)
        }
        
        return channelCount
    }
    
    /// サンプルレートを取得
    private func getDeviceSampleRate(_ deviceID: AudioDeviceID) -> Double {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var sampleRate: Float64 = 44100.0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &sampleRate)
        
        return sampleRate
    }
    
    /// 文字列プロパティの汎用取得メソッド
    private func getStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var cfString: Unmanaged<CFString>?
        
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &cfString)
        guard status == noErr, let unmanagedString = cfString else { return nil }
        
        return unmanagedString.takeUnretainedValue() as String
    }
    
    // MARK: - Default Device
    
    /// デフォルトデバイスを取得
    func getDefaultDevice(for type: AudioDeviceType) -> AudioDevice? {
        let selector: AudioObjectPropertySelector
        switch type {
        case .input:
            selector = kAudioHardwarePropertyDefaultInputDevice
        case .output:
            selector = kAudioHardwarePropertyDefaultOutputDevice
        case .all:
            return nil
        }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        
        guard status == noErr, deviceID != 0 else { return nil }
        
        return allDevices.first { $0.id == deviceID } ?? createAudioDevice(from: deviceID)
    }
    
    // MARK: - Device Lookup
    
    /// UIDでデバイスを検索
    func findDevice(byUID uid: String) -> AudioDevice? {
        allDevices.first { $0.uid == uid }
    }
    
    /// 名前でデバイスを検索
    func findDevice(byName name: String) -> AudioDevice? {
        allDevices.first { $0.name == name }
    }
    
    /// UIDで検索し、見つからない場合は名前で検索、それでも見つからない場合はデフォルトデバイスにフォールバック
    func resolveDevice(uid: String, name: String, type: AudioDeviceType) -> (device: AudioDevice?, matchType: DeviceMatchType) {
        // 1. UIDで完全一致
        if let device = findDevice(byUID: uid) {
            return (device, .exactUID)
        }
        
        // 2. 名前で一致
        if let device = findDevice(byName: name) {
            logger.info("Device UID '\(uid)' not found, matched by name: '\(name)'")
            return (device, .nameMatch)
        }
        
        // 3. デフォルトデバイスにフォールバック
        if let defaultDevice = getDefaultDevice(for: type) {
            logger.warning("Device '\(name)' (UID: \(uid)) not found, falling back to default: '\(defaultDevice.name)'")
            return (defaultDevice, .fallbackDefault)
        }
        
        logger.error("No device found for '\(name)' (UID: \(uid)) and no default available")
        return (nil, .notFound)
    }
    
    /// AudioDeviceID が現在も有効かチェック
    func isDeviceValid(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(deviceID, &propertyAddress)
    }
}

/// デバイス照合結果の種別
enum DeviceMatchType {
    case exactUID       // UIDで完全一致
    case nameMatch      // 名前で一致（UIDは変更）
    case fallbackDefault // デフォルトデバイスにフォールバック
    case notFound       // デバイス見つからず
}
