import Foundation

/// ミキサー全体のルーティング設定を管理
class AudioRoute: ObservableObject {
    /// 入力チャンネル（4つ）
    @Published var inputChannels: [MixerChannel]
    
    /// 出力バス（4つ）
    @Published var outputBuses: [MixerChannel]
    
    /// ソロが有効なチャンネルがあるか
    var hasSoloEnabled: Bool {
        inputChannels.contains { $0.isSolo }
    }
    
    init() {
        inputChannels = (0..<4).map { MixerChannel(id: $0, channelType: .input) }
        outputBuses = (0..<4).map { MixerChannel(id: $0, channelType: .output) }
    }
    
    /// 特定の出力バスにルーティングされている入力チャンネルを返す
    func inputsRouted(to outputBusIndex: Int) -> [MixerChannel] {
        guard outputBusIndex >= 0 && outputBusIndex < 4 else { return [] }
        return inputChannels.filter { channel in
            channel.routingToOutputs.indices.contains(outputBusIndex) &&
            channel.routingToOutputs[outputBusIndex]
        }
    }
    
    /// ソロ状態を考慮した実効的なミュート状態を返す
    func isEffectivelyMuted(_ channel: MixerChannel) -> Bool {
        if channel.isMuted { return true }
        if hasSoloEnabled && !channel.isSolo { return true }
        return false
    }
    
    // MARK: - Configuration Persistence
    
    /// 現在の設定をJSON形式で保存
    func saveConfiguration() -> MixerConfiguration {
        MixerConfiguration(
            inputs: inputChannels.map { MixerChannelConfiguration(from: $0) },
            outputs: outputBuses.map { MixerChannelConfiguration(from: $0) }
        )
    }
    
    /// 保存された設定を復元（デバイスの照合は呼び出し元で行う）
    func restoreConfiguration(_ config: MixerConfiguration) {
        for (index, inputConfig) in config.inputs.enumerated() where index < inputChannels.count {
            let channel = inputChannels[index]
            channel.volume = inputConfig.volume
            channel.pan = inputConfig.pan
            channel.isMuted = inputConfig.isMuted
            channel.routingToOutputs = inputConfig.routingToOutputs
            channel.selectedDeviceUID = inputConfig.deviceUID
            channel.targetDeviceUID = inputConfig.deviceUID
        }
        
        for (index, outputConfig) in config.outputs.enumerated() where index < outputBuses.count {
            let channel = outputBuses[index]
            channel.volume = outputConfig.volume
            channel.pan = outputConfig.pan
            channel.isMuted = outputConfig.isMuted
            channel.selectedDeviceUID = outputConfig.deviceUID
            channel.targetDeviceUID = outputConfig.deviceUID
        }
    }
    
    /// UserDefaultsに設定を永続化
    func saveToDisk() {
        let config = saveConfiguration()
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "MixerConfiguration")
        }
    }
    
    /// UserDefaultsから設定を復元
    func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: "MixerConfiguration"),
              let config = try? JSONDecoder().decode(MixerConfiguration.self, from: data) else {
            return
        }
        restoreConfiguration(config)
    }
}

/// ミキサー全体の設定（永続化用）
struct MixerConfiguration: Codable {
    let inputs: [MixerChannelConfiguration]
    let outputs: [MixerChannelConfiguration]
}
