import Foundation
import CoreAudio

/// システム上のオーディオデバイスを表すモデル
struct AudioDevice: Identifiable, Hashable {
    /// Core Audio のデバイスID（揮発的、スリープ前後で変わる可能性あり）
    let id: AudioDeviceID
    
    /// デバイスの永続的なUID（スリープ/再起動後もデバイスを識別可能）
    let uid: String
    
    /// デバイスの表示名
    let name: String
    
    /// メーカー名
    let manufacturer: String
    
    /// 入力チャンネル数（0 の場合は入力非対応）
    let inputChannelCount: Int
    
    /// 出力チャンネル数（0 の場合は出力非対応）
    let outputChannelCount: Int
    
    /// 対応サンプルレート
    let sampleRate: Double
    
    /// デバイスがオーディオ入力に対応しているか
    var isInput: Bool { inputChannelCount > 0 }
    
    /// デバイスがオーディオ出力に対応しているか
    var isOutput: Bool { outputChannelCount > 0 }
    
    /// 「(なし)」を表すダミーデバイス
    static let none = AudioDevice(
        id: 0,
        uid: "",
        name: "(なし)",
        manufacturer: "",
        inputChannelCount: 0,
        outputChannelCount: 0,
        sampleRate: 44100.0
    )
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(uid)
    }
    
    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.uid == rhs.uid
    }
}

/// デバイスの種別フィルター
enum AudioDeviceType {
    case input
    case output
    case all
}
