import Foundation

/// ミキサーの入力チャンネルまたは出力バスを表すモデル
class MixerChannel: ObservableObject, Identifiable {
    let id: Int
    let channelType: ChannelType
    
    /// 選択されているデバイスのUID（永続化用）
    @Published var selectedDeviceUID: String = ""
    
    /// ユーザーが最後に意図して選択したデバイスのUID（自動復帰用）
    @Published var targetDeviceUID: String = ""
    
    /// 選択されているデバイス
    @Published var selectedDevice: AudioDevice = .none
    
    /// ボリューム（0.0 〜 1.43 ブースト対応）
    @Published var volume: Float = 1.0
    
    /// ゲイン（入力チャンネルのみ、0.0 〜 4.0、プリアンプ相当）
    @Published var gain: Float = 1.0
    
    /// パン（-1.0: 左, 0.0: センター, 1.0: 右）
    @Published var pan: Float = 0.0
    
    // MARK: - カスタム名称
    /// カスタム名称（空の場合はデフォルト名）
    @Published var customName: String = ""
    
    // MARK: - ノイズゲート（入力チャンネルのみ）
    @Published var noiseGateEnabled: Bool = false
    @Published var noiseGateThreshold: Float = -50.0
    
    // MARK: - EQ (ローカット)（入力チャンネルのみ）
    @Published var eqEnabled: Bool = false
    @Published var eqLowCutFrequency: Float = 80.0
    
    // MARK: - コンプレッサー（入力チャンネルのみ）
    
    /// コンプレッサー有効/無効
    @Published var compressorEnabled: Bool = false
    
    /// スレッショルド（dBFS, -40〜0）
    @Published var compressorThreshold: Float = -20.0
    
    /// レシオ / ヘッドルーム（dB, 0.1〜40.0）※AppleのDynamicsProcessorはRatioの代わりにHeadRoomを使用します
    @Published var compressorHeadRoom: Float = 5.0
    
    /// アタックタイム（秒, 0.001〜0.200）
    @Published var compressorAttack: Float = 0.010
    
    /// リリースタイム（秒, 0.010〜3.0）
    @Published var compressorRelease: Float = 0.100
    
    /// メイクアップゲイン（dB, 0〜40）
    @Published var compressorMakeupGain: Float = 0.0
    
    // MARK: - リミッター（出力バスのみ）
    
    /// ピークリミッター有効/無効
    @Published var limiterEnabled: Bool = false
    
    // MARK: - ミュート / ソロ / ルーティング
    @Published var isMuted: Bool = false
    
    /// ソロ状態（入力チャンネルのみ使用）
    @Published var isSolo: Bool = false
    
    /// 各出力バスへのルーティング（入力チャンネルのみ使用、インデックスはバス番号）
    @Published var routingToOutputs: [Bool] = [true, false, false, false]
    
    /// 現在のレベル（L, R）: dBFS
    @Published var levelL: Float = -Float.infinity
    @Published var levelR: Float = -Float.infinity
    
    /// ピークホールド（L, R）: dBFS
    @Published var peakL: Float = -Float.infinity
    @Published var peakR: Float = -Float.infinity
    
    init(id: Int, channelType: ChannelType) {
        self.id = id
        self.channelType = channelType
        
        // 入力チャンネル0はデフォルトで出力バス0にルーティング
        if channelType == .input {
            routingToOutputs = Array(repeating: false, count: 4)
            if id < 4 {
                routingToOutputs[0] = true
            }
        }
    }
    
    /// 実効ボリューム（ミュート考慮）
    var effectiveVolume: Float {
        isMuted ? 0.0 : volume
    }
    
    /// 実効ゲイン（ミュート考慮）
    var effectiveGain: Float {
        isMuted ? 0.0 : gain
    }
    
    enum ChannelType: String, Codable {
        case input
        case output
    }
}

// MARK: - Codable Configuration

/// チャンネル設定の永続化用構造体
struct MixerChannelConfiguration: Codable {
    let channelId: Int
    let channelType: MixerChannel.ChannelType
    let deviceUID: String
    let deviceName: String
    let volume: Float
    let pan: Float
    let isMuted: Bool
    let routingToOutputs: [Bool]
    
    init(from channel: MixerChannel) {
        self.channelId = channel.id
        self.channelType = channel.channelType
        self.deviceUID = channel.selectedDeviceUID
        self.deviceName = channel.selectedDevice.name
        self.volume = channel.volume
        self.pan = channel.pan
        self.isMuted = channel.isMuted
        self.routingToOutputs = channel.routingToOutputs
    }
}
