import Foundation
import CoreAudio
import AVFoundation
import os.log

/// Core Audio HALリスナーを管理し、デバイスの接続/切断をリアルタイムで監視する
class AudioDeviceMonitor {
    private let logger = AppLogger(category: "AudioDeviceMonitor")
    
    /// 依存オブジェクト
    private let deviceManager: AudioDeviceManager
    private let mixerEngine: AudioMixerEngine
    private let audioRoute: AudioRoute
    
    /// リスナー処理用シリアルキュー
    private let listenerQueue = DispatchQueue(label: "com.multicast.deviceMonitor", qos: .userInitiated)
    
    /// 現在のデバイスリスト（差分検知用）
    private var currentDeviceUIDs: Set<String> = []
    
    /// デバウンス用タイマー
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.5
    
    init(deviceManager: AudioDeviceManager, mixerEngine: AudioMixerEngine, audioRoute: AudioRoute) {
        self.deviceManager = deviceManager
        self.mixerEngine = mixerEngine
        self.audioRoute = audioRoute
        
        // 初期デバイスリストを記録
        currentDeviceUIDs = Set(deviceManager.allDevices.map { $0.uid })
        
        setupListeners()
    }
    
    // MARK: - Listener Setup
    
    private func setupListeners() {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        
        // 1. デバイス一覧の変更を監視
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectAddPropertyListenerBlock(
            systemObjectID,
            &devicesAddress,
            listenerQueue
        ) { [weak self] _, _ in
            self?.handleDeviceListChangedDebounced()
        }
        
        // 2. デフォルト入力デバイスの変更を監視
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectAddPropertyListenerBlock(
            systemObjectID,
            &defaultInputAddress,
            listenerQueue
        ) { [weak self] _, _ in
            self?.handleDefaultDeviceChanged(type: .input)
        }
        
        // 3. デフォルト出力デバイスの変更を監視
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectAddPropertyListenerBlock(
            systemObjectID,
            &defaultOutputAddress,
            listenerQueue
        ) { [weak self] _, _ in
            self?.handleDefaultDeviceChanged(type: .output)
        }
        
        // 4. AVAudioEngine 設定変更通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
        
        logger.info("Device listeners registered")
    }
    
    // MARK: - Device List Change Handling
    
    /// デバウンス付きでデバイスリスト変更を処理（短時間に複数回呼ばれることがあるため）
    private func handleDeviceListChangedDebounced() {
        debounceWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleDeviceListChanged()
        }
        
        debounceWorkItem = workItem
        listenerQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
    
    private func handleDeviceListChanged() {
        logger.info("Device list changed — scanning for differences")
        
        // デバイス一覧を再取得
        let freshDevices = deviceManager.refreshDevices()
        let newUIDs = Set(freshDevices.map { $0.uid })
        
        // 差分を計算
        let addedUIDs = newUIDs.subtracting(currentDeviceUIDs)
        let removedUIDs = currentDeviceUIDs.subtracting(newUIDs)
        
        if !addedUIDs.isEmpty {
            let addedNames = freshDevices.filter { addedUIDs.contains($0.uid) }.map { $0.name }
            logger.info("Devices added: \(addedNames.joined(separator: ", "))")
        }
        
        if !removedUIDs.isEmpty {
            logger.info("Devices removed: UIDs \(removedUIDs.joined(separator: ", "))")
        }
        
        // 使用中のデバイスが消えたか確認
        for channel in audioRoute.inputChannels {
            if !channel.selectedDeviceUID.isEmpty && removedUIDs.contains(channel.selectedDeviceUID) {
                handleActiveDeviceLost(channel: channel, type: .input)
            }
        }
        
        for bus in audioRoute.outputBuses {
            if !bus.selectedDeviceUID.isEmpty && removedUIDs.contains(bus.selectedDeviceUID) {
                handleActiveDeviceLost(channel: bus, type: .output)
            }
        }
        
        // ターゲットデバイスが復活した場合の自動リカバリ
        var needsRebuild = false
        for channel in audioRoute.inputChannels {
            if !channel.targetDeviceUID.isEmpty && channel.targetDeviceUID != channel.selectedDeviceUID {
                let targetUID = channel.targetDeviceUID
                if let device = freshDevices.first(where: { $0.uid == targetUID && $0.isInput }) {
                    logger.info("Auto-recovering Input \(channel.id + 1) to device '\(device.name)'")
                    DispatchQueue.main.async {
                        channel.selectedDevice = device
                        channel.selectedDeviceUID = device.uid
                    }
                    needsRebuild = true
                }
            }
        }
        for bus in audioRoute.outputBuses {
            if !bus.targetDeviceUID.isEmpty && bus.targetDeviceUID != bus.selectedDeviceUID {
                let targetUID = bus.targetDeviceUID
                if let device = freshDevices.first(where: { $0.uid == targetUID && $0.isOutput }) {
                    logger.info("Auto-recovering Output \(bus.id + 1) to device '\(device.name)'")
                    DispatchQueue.main.async {
                        bus.selectedDevice = device
                        bus.selectedDeviceUID = device.uid
                    }
                    needsRebuild = true
                }
            }
        }
        
        if needsRebuild {
            mixerEngine.rebuild()
        }
        
        // 状態を更新
        currentDeviceUIDs = newUIDs
        
        // UI更新
        DispatchQueue.main.async { [weak self] in
            self?.deviceManager.objectWillChange.send()
            self?.audioRoute.objectWillChange.send()
        }
    }
    
    // MARK: - Active Device Lost
    
    /// 使用中のデバイスが消失した場合の処理
    private func handleActiveDeviceLost(channel: MixerChannel, type: AudioDeviceType) {
        let deviceName = channel.selectedDevice.name
        let channelId = channel.id
        
        logger.warning("\(type == .input ? "Input" : "Output") \(channelId): Device '\(deviceName)' lost")
        
        // デフォルトデバイスにフォールバック (targetDeviceUID はそのまま維持)
        if let defaultDevice = deviceManager.getDefaultDevice(for: type) {
            DispatchQueue.main.async {
                channel.selectedDevice = defaultDevice
                channel.selectedDeviceUID = defaultDevice.uid
            }
            logger.info("Fell back to default device: '\(defaultDevice.name)'")
        } else {
            DispatchQueue.main.async {
                channel.selectedDevice = .none
                channel.selectedDeviceUID = ""
            }
        }
        
        // エンジンを再構築
        mixerEngine.rebuild()
    }
    
    // MARK: - Default Device Change
    
    /// デフォルトデバイスが変更された場合
    private func handleDefaultDeviceChanged(type: AudioDeviceType) {
        let deviceTypeName = type == .input ? "input" : "output"
        logger.info("Default \(deviceTypeName) device changed")
        
        // デバイスリストを更新
        deviceManager.refreshDevices()
        
        DispatchQueue.main.async { [weak self] in
            self?.deviceManager.objectWillChange.send()
        }
    }
    
    /// デバウンス用（設定変更通知用）
    private var configChangeWorkItem: DispatchWorkItem?
    
    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        // リビルド中の通知は無視（自分自身の起動による通知ループ防止）
        guard !mixerEngine.isRebuilding else {
            logger.debug("Ignoring config change during active rebuild")
            return
        }
        
        // デバウンス: 短時間に複数回呼ばれることがあるため
        configChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard !self.mixerEngine.isRebuilding else { return }
            self.logger.warning("AVAudioEngine configuration changed — triggering rebuild")
            self.mixerEngine.rebuild()
        }
        configChangeWorkItem = workItem
        listenerQueue.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }
    
    // MARK: - Cleanup
    
    func removeListeners() {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(systemObjectID, &devicesAddress, listenerQueue, { _, _ in })
        
        NotificationCenter.default.removeObserver(self)
        
        logger.info("Device listeners removed")
    }
}
