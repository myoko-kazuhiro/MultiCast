import Foundation
import CoreAudio
import os.log

/// 定期的にオーディオエンジンの健全性をチェックする（Layer 4: セーフティネット）
class AudioHealthMonitor {
    private let logger = AppLogger(category: "AudioHealthMonitor")
    
    /// 依存オブジェクト
    private let mixerEngine: AudioMixerEngine
    private let deviceManager: AudioDeviceManager
    private let audioRoute: AudioRoute
    
    /// リカバリハンドラ
    var onRecoveryNeeded: ((RecoveryReason) -> Void)?
    
    /// ヘルスチェックタイマー
    private var timer: Timer?
    
    /// チェック間隔（秒）
    private let checkInterval: TimeInterval = 3.0
    
    /// 無音カウンター
    private var silenceCounter = 0
    
    /// 無音判定の閾値（連続回数）: 3秒 × 5回 = 15秒
    private let silenceThreshold = 5
    
    /// 無音判定のレベル（dBFS）
    private let silenceLevelThreshold: Float = -96.0
    
    init(mixerEngine: AudioMixerEngine, deviceManager: AudioDeviceManager, audioRoute: AudioRoute) {
        self.mixerEngine = mixerEngine
        self.deviceManager = deviceManager
        self.audioRoute = audioRoute
    }
    
    // MARK: - Start / Stop
    
    /// ヘルスチェックを開始
    func startMonitoring() {
        stopMonitoring()
        
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.performHealthCheck()
        }
        
        logger.info("Health monitoring started (interval: \(self.checkInterval)s)")
    }
    
    /// ヘルスチェックを停止
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        silenceCounter = 0
        logger.info("Health monitoring stopped")
    }
    
    // MARK: - Health Check
    
    private func performHealthCheck() {
        // エンジンが running を主張しているか
        guard mixerEngine.state == .running else {
            // suspended や recovering 中は何もしない
            if mixerEngine.state == .stopped || mixerEngine.state == .error {
                // 停止状態やエラー状態なのにモニタリングが動いている場合は無視
            }
            return
        }
        
        // 使用中のデバイスIDがまだ有効かチェック
        for channel in audioRoute.inputChannels {
            guard channel.selectedDevice.id != 0 else { continue }
            
            if !deviceManager.isDeviceValid(channel.selectedDevice.id) {
                logger.warning("Input \(channel.id): Device ID \(channel.selectedDevice.id) is no longer valid")
                triggerRecovery(reason: .deviceInvalidated(
                    channelId: channel.id,
                    channelType: .input,
                    deviceName: channel.selectedDevice.name
                ))
                return
            }
        }
        
        for bus in audioRoute.outputBuses {
            guard bus.selectedDevice.id != 0 else { continue }
            
            if !deviceManager.isDeviceValid(bus.selectedDevice.id) {
                logger.warning("Output \(bus.id): Device ID \(bus.selectedDevice.id) is no longer valid")
                triggerRecovery(reason: .deviceInvalidated(
                    channelId: bus.id,
                    channelType: .output,
                    deviceName: bus.selectedDevice.name
                ))
                return
            }
        }
        
        // 入力があるはずなのにレベルがゼロかチェック
        let hasActiveInputs = audioRoute.inputChannels.contains { $0.selectedDevice.id != 0 }
        
        if hasActiveInputs {
            let maxLevel = audioRoute.inputChannels
                .filter { $0.selectedDevice.id != 0 }
                .map { max($0.levelL, $0.levelR) }
                .max() ?? silenceLevelThreshold
            
            if maxLevel < silenceLevelThreshold {
                silenceCounter += 1
                
                if silenceCounter >= silenceThreshold {
                    logger.warning("Prolonged silence detected (\(self.silenceCounter) checks)")
                    triggerRecovery(reason: .prolongedSilence)
                    silenceCounter = 0
                }
            } else {
                silenceCounter = 0
            }
        }
    }
    
    // MARK: - Recovery Trigger
    
    private func triggerRecovery(reason: RecoveryReason) {
        logger.warning("Health check triggered recovery: \(reason.description)")
        onRecoveryNeeded?(reason)
    }
}

// MARK: - Recovery Reason

/// リカバリが必要な理由
enum RecoveryReason {
    case engineStopped
    case deviceInvalidated(channelId: Int, channelType: MixerChannel.ChannelType, deviceName: String)
    case prolongedSilence
    
    var description: String {
        switch self {
        case .engineStopped:
            return "Engine stopped unexpectedly"
        case .deviceInvalidated(let channelId, let channelType, let deviceName):
            return "\(channelType.rawValue.capitalized) \(channelId): Device '\(deviceName)' invalidated"
        case .prolongedSilence:
            return "Prolonged silence detected on active inputs"
        }
    }
}
