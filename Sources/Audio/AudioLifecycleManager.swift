import Foundation
import AppKit
import UserNotifications
import os.log

/// スリープ/復帰のライフサイクルを管理し、オーディオエンジンの安全な停止・再開を行う
class AudioLifecycleManager: ObservableObject {
    private let logger = AppLogger(category: "AudioLifecycleManager")
    
    /// 依存オブジェクト
    private let mixerEngine: AudioMixerEngine
    private let deviceManager: AudioDeviceManager
    private let audioRoute: AudioRoute
    
    /// スリープ前に保存した設定
    private var savedConfiguration: MixerConfiguration?
    
    /// リカバリのリトライ設定
    private let maxRetryAttempts = 3
    private let baseRetryDelay: TimeInterval = 1.0
    
    /// 復帰後の待機時間（USBデバイス列挙待ち）
    private let wakeSettleDelay: TimeInterval = 1.5
    
    /// 復帰通知を受け取ったかのフラグ（重複防止）
    private var isRecovering = false
    
    init(mixerEngine: AudioMixerEngine, deviceManager: AudioDeviceManager, audioRoute: AudioRoute) {
        self.mixerEngine = mixerEngine
        self.deviceManager = deviceManager
        self.audioRoute = audioRoute
        
        setupNotifications()
    }
    
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    // MARK: - Notification Setup
    
    private func setupNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        
        // スリープ前の通知
        center.addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        
        // 復帰後の通知
        center.addObserver(
            self,
            selector: #selector(handleDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        // スクリーンロック解除（追加の安全ネット）
        center.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }
    
    // MARK: - Layer 1: Pre-Sleep Teardown
    
    @objc private func handleWillSleep() {
        logger.info("System will sleep — performing pre-sleep teardown")
        
        // 1. 現在の設定をDeviceUIDベースで保存
        savedConfiguration = audioRoute.saveConfiguration()
        
        // 2. UserDefaultsにも永続化（クラッシュ対策）
        audioRoute.saveToDisk()
        
        // 3. エンジンを安全に停止（engineQueueで排他制御される）
        mixerEngine.stop()
        
        // 4. 状態を suspended に設定
        DispatchQueue.main.async { [weak self] in
            self?.mixerEngine.state = .suspended
        }
        
        logger.info("Pre-sleep teardown complete. Configuration saved.")
    }
    
    // MARK: - Layer 2: Wake Recovery
    
    @objc private func handleDidWake() {
        logger.info("System did wake — scheduling recovery")
        
        guard !isRecovering else {
            logger.info("Recovery already in progress, skipping duplicate wake notification")
            return
        }
        
        isRecovering = true
        
        DispatchQueue.main.async { [weak self] in
            self?.mixerEngine.state = .recovering
        }
        
        // USBデバイスの列挙完了を待ってからリカバリを開始
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + wakeSettleDelay) { [weak self] in
            self?.performWakeRecovery()
        }
    }
    
    @objc private func handleScreensDidWake() {
        // スクリーンが復帰した場合、まだリカバリが実行されていなければ実行
        logger.debug("Screens did wake notification received")
        
        if mixerEngine.state == .suspended && !isRecovering {
            handleDidWake()
        }
    }
    
    // MARK: - Recovery Logic
    
    private func performWakeRecovery() {
        logger.info("Starting wake recovery...")
        
        // 1. デバイス一覧を再取得
        let freshDevices = deviceManager.refreshDevices()
        logger.info("Found \(freshDevices.count) devices after wake")
        
        // 2. 保存した設定をDeviceUID照合で復元
        guard let savedConfig = savedConfiguration else {
            logger.warning("No saved configuration found, starting with defaults")
            startEngineWithRetry()
            return
        }
        
        // 3. 各チャンネルのデバイスを照合・復元（@Publishedの変更はメインスレッドで行う）
        if Thread.isMainThread {
            restoreChannelDevices(from: savedConfig)
        } else {
            DispatchQueue.main.sync {
                restoreChannelDevices(from: savedConfig)
            }
        }
        
        // 4. エンジンをリトライ付きで起動
        startEngineWithRetry()
    }
    
    /// チャンネルごとにデバイスを照合して復元
    private func restoreChannelDevices(from config: MixerConfiguration) {
        var unmatchedDevices: [(channelType: String, channelId: Int, deviceName: String)] = []
        
        // 入力チャンネルの復元
        for inputConfig in config.inputs {
            guard inputConfig.channelId < audioRoute.inputChannels.count else { continue }
            let channel = audioRoute.inputChannels[inputConfig.channelId]
            
            // ボリューム、パン、ミュート、ルーティングを復元
            channel.volume = inputConfig.volume
            channel.pan = inputConfig.pan
            channel.isMuted = inputConfig.isMuted
            channel.routingToOutputs = inputConfig.routingToOutputs
            
            if !inputConfig.deviceUID.isEmpty {
                let result = deviceManager.resolveDevice(
                    uid: inputConfig.deviceUID,
                    name: inputConfig.deviceName,
                    type: .input
                )
                
                if let device = result.device {
                    channel.selectedDevice = device
                    channel.selectedDeviceUID = device.uid
                    
                    if result.matchType == .fallbackDefault {
                        unmatchedDevices.append(("Input", inputConfig.channelId, inputConfig.deviceName))
                    }
                } else {
                    channel.selectedDevice = .none
                    channel.selectedDeviceUID = ""
                    unmatchedDevices.append(("Input", inputConfig.channelId, inputConfig.deviceName))
                }
            }
        }
        
        // 出力バスの復元
        for outputConfig in config.outputs {
            guard outputConfig.channelId < audioRoute.outputBuses.count else { continue }
            let channel = audioRoute.outputBuses[outputConfig.channelId]
            
            channel.volume = outputConfig.volume
            channel.pan = outputConfig.pan
            channel.isMuted = outputConfig.isMuted
            
            if !outputConfig.deviceUID.isEmpty {
                let result = deviceManager.resolveDevice(
                    uid: outputConfig.deviceUID,
                    name: outputConfig.deviceName,
                    type: .output
                )
                
                if let device = result.device {
                    channel.selectedDevice = device
                    channel.selectedDeviceUID = device.uid
                    
                    if result.matchType == .fallbackDefault {
                        unmatchedDevices.append(("Output", outputConfig.channelId, outputConfig.deviceName))
                    }
                } else {
                    channel.selectedDevice = .none
                    channel.selectedDeviceUID = ""
                    unmatchedDevices.append(("Output", outputConfig.channelId, outputConfig.deviceName))
                }
            }
        }
        
        // 見つからなかったデバイスをユーザーに通知
        if !unmatchedDevices.isEmpty {
            let messages = unmatchedDevices.map { "\($0.channelType) \($0.channelId + 1): \($0.deviceName)" }
            logger.warning("Unmatched devices after wake: \(messages.joined(separator: ", "))")
            
            DispatchQueue.main.async { [weak self] in
                self?.notifyUnmatchedDevices(unmatchedDevices)
            }
        }
    }
    
    // MARK: - Retry Logic
    
    /// リトライ付きでエンジンを起動
    private func startEngineWithRetry(attempt: Int = 1) {
        logger.info("Engine start attempt \(attempt)/\(self.maxRetryAttempts)")
        
        mixerEngine.start()
        
        // 起動結果を少し待って確認
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            if self.mixerEngine.state == .running {
                self.logger.info("Engine started successfully on attempt \(attempt)")
                self.isRecovering = false
                return
            }
            
            if attempt < self.maxRetryAttempts {
                // 指数バックオフで再試行
                let delay = self.baseRetryDelay * Double(attempt)
                self.logger.info("Engine start failed, retrying in \(delay)s...")
                
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                    self.startEngineWithRetry(attempt: attempt + 1)
                }
            } else {
                self.logger.error("Engine start failed after \(self.maxRetryAttempts) attempts")
                self.isRecovering = false
                
                DispatchQueue.main.async {
                    self.mixerEngine.state = .error
                    self.notifyRecoveryFailure()
                }
            }
        }
    }
    
    // MARK: - User Notifications
    
    /// デバイスが見つからなかったことをユーザーに通知
    private func notifyUnmatchedDevices(_ devices: [(channelType: String, channelId: Int, deviceName: String)]) {
        let deviceList = devices.map { "\($0.channelType) \($0.channelId + 1): \($0.deviceName)" }.joined(separator: "\n")
        
        let content = UNMutableNotificationContent()
        content.title = "MultiCast - デバイス変更"
        content.body = "以下のデバイスが見つかりません。デフォルトデバイスに切り替えました:\n\(deviceList)"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                self.logger.error("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }
    
    /// リカバリ失敗をユーザーに通知
    private func notifyRecoveryFailure() {
        let content = UNMutableNotificationContent()
        content.title = "MultiCast - エラー"
        content.body = "オーディオエンジンの再起動に失敗しました。デバイスの接続を確認してください。"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                self.logger.error("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Manual Recovery
    
    /// 手動リカバリを実行（UIからの操作用）
    func manualRecovery() {
        logger.info("Manual recovery triggered by user")
        isRecovering = false
        
        DispatchQueue.main.async { [weak self] in
            self?.mixerEngine.state = .recovering
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performWakeRecovery()
        }
    }
}
