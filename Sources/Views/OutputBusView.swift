import SwiftUI

/// 出力バスの表示コンポーネント
struct OutputBusView: View {
    @ObservedObject var channel: MixerChannel
    @ObservedObject var deviceManager: AudioDeviceManager
    
    /// デバイス変更時のコールバック
    var onDeviceChanged: ((AudioDevice) -> Void)?
    
    var body: some View {
        VStack(spacing: 8) {
            // バス番号ラベル (クリックで名前変更)
            TextField("Output \(channel.id + 1)", text: $channel.customName)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(busHeaderColor)
                )
            
            // デバイス選択
            Picker("", selection: Binding(
                get: { channel.selectedDeviceUID },
                set: { uid in
                    channel.targetDeviceUID = uid
                    if uid.isEmpty {
                        onDeviceChanged?(.none)
                    } else if let device = deviceManager.outputDevices.first(where: { $0.uid == uid }) {
                        onDeviceChanged?(device)
                    }
                }
            )) {
                Text("(なし)").tag("")
                ForEach(deviceManager.outputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .controlSize(.small)
            
            // レベルメーター + フェーダー
            HStack(spacing: 6) {
                // ステレオレベルメーター
                StereoLevelMeterView(
                    levelL: channel.levelL,
                    levelR: channel.levelR,
                    peakL: channel.peakL,
                    peakR: channel.peakR,
                    thickness: 4
                )
                .frame(width: 12)
                
                // ボリュームフェーダー
                VStack(spacing: 2) {
                    // dB表示
                    Text(volumeDBString)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    VerticalSlider(value: $channel.volume, range: 0...1.43, trackColor: .cyan)
                        .frame(width: 24)
                }
            }
            .frame(height: 100)
            
            // ミュート & リミッター ボタン
            HStack(spacing: 8) {
                Button(action: { channel.isMuted.toggle() }) {
                    Text("M")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 20)
                        .background(channel.isMuted ? Color.red : Color.gray.opacity(0.4))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                
                Button(action: { channel.limiterEnabled.toggle() }) {
                    Text("LIM")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(channel.limiterEnabled ? .black : .white)
                        .frame(width: 30, height: 20)
                        .background(channel.limiterEnabled ? Color.yellow : Color.gray.opacity(0.4))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 130)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.15))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(white: 0.25), lineWidth: 1)
        )
    }
    
    private var busHeaderColor: Color {
        let hues: [Double] = [0.6, 0.45, 0.3, 0.75]
        let hue = channel.id < hues.count ? hues[channel.id] : 0.5
        return Color(hue: hue, saturation: 0.5, brightness: 0.6)
    }
    
    private var volumeDBString: String {
        if channel.volume <= 0.001 { return "-∞" }
        let db = 20.0 * log10(channel.volume)
        return String(format: "%.1f", db)
    }
}
