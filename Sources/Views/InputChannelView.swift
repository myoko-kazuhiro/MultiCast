import SwiftUI

/// 入力チャンネルの表示コンポーネント
struct InputChannelView: View {
    @ObservedObject var channel: MixerChannel
    @ObservedObject var deviceManager: AudioDeviceManager
    let outputBusCount: Int
    let isCompressorSelected: Bool
    
    /// デバイス変更時のコールバック
    var onDeviceChanged: ((AudioDevice) -> Void)?
    
    /// コンプレッサーパネルを切り替えるコールバック
    var onCompressorToggle: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 8) {
            // チャンネル番号ラベル (クリックで名前変更)
            TextField("Input \(channel.id + 1)", text: $channel.customName)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(channelHeaderColor)
                )
            
            // デバイス選択
            Picker("", selection: Binding(
                get: { channel.selectedDeviceUID },
                set: { uid in
                    channel.targetDeviceUID = uid
                    if uid.isEmpty {
                        onDeviceChanged?(.none)
                    } else if let device = deviceManager.inputDevices.first(where: { $0.uid == uid }) {
                        onDeviceChanged?(device)
                    }
                }
            )) {
                Text("(なし)").tag("")
                ForEach(deviceManager.inputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .controlSize(.small)
            
            // レベルメーター + Vol + Gain スライダー
            HStack(spacing: 5) {
                // ステレオレベルメーター
                StereoLevelMeterView(
                    levelL: channel.levelL,
                    levelR: channel.levelR,
                    peakL: channel.peakL,
                    peakR: channel.peakR,
                    thickness: 4
                )
                .frame(width: 12)
                
                // Vol フェーダー
                VStack(spacing: 2) {
                    Text(volumeDBString)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    VerticalSlider(value: $channel.volume, range: 0...1.43, trackColor: .blue)
                        .frame(width: 18)
                    Text("Vol")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Color(white: 0.6))
                }
                
                // Gain フェーダー
                VStack(spacing: 2) {
                    Text(gainDBString)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    VerticalSlider(value: $channel.gain, range: 0...4.0, trackColor: .orange)
                        .frame(width: 18)
                    Text("Gain")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Color(white: 0.6))
                }
            }
            .frame(height: 130)
            
            // パンスライダー
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text("L")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                    Slider(value: $channel.pan, in: -1...1)
                        .controlSize(.mini)
                    Text("R")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
                Text(panString)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            
            // M / S / COMPトグル行
            HStack(spacing: 4) {
                Button(action: { channel.isMuted.toggle() }) {
                    Text("M")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 20)
                        .background(channel.isMuted ? Color.red : Color.gray.opacity(0.4))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                
                Button(action: { channel.isSolo.toggle() }) {
                    Text("S")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 20)
                        .background(channel.isSolo ? Color.yellow.opacity(0.8) : Color.gray.opacity(0.4))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                
                // エフェクト(Inspector)開閉ボタン
                Button(action: { onCompressorToggle?() }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isCompressorSelected ? .black : (channel.compressorEnabled || channel.noiseGateEnabled || channel.eqEnabled ? .cyan : Color(white: 0.7)))
                        .frame(width: 28, height: 20)
                        .background(
                            isCompressorSelected
                            ? Color.cyan
                            : Color.gray.opacity(0.4)
                        )
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 130)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.18))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(white: 0.28), lineWidth: 1)
        )
    }
    
    private var channelHeaderColor: Color {
        let hues: [Double] = [0.55, 0.35, 0.12, 0.8]
        let hue = channel.id < hues.count ? hues[channel.id] : 0.5
        return Color(hue: hue, saturation: 0.6, brightness: 0.7)
    }
    
    private var volumeDBString: String {
        if channel.volume <= 0.001 { return "-∞" }
        let db = 20.0 * log10(channel.volume)
        return String(format: "%.1f", db)
    }
    
    private var gainDBString: String {
        if channel.gain <= 0.001 { return "-∞" }
        let db = 20.0 * log10(channel.gain)
        return String(format: "%+.1f", db)
    }
    
    private var panString: String {
        if abs(channel.pan) < 0.01 { return "C" }
        let side = channel.pan < 0 ? "L" : "R"
        return "\(side)\(Int(abs(channel.pan * 100)))%"
    }
}

/// 縦型スライダー
struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var trackColor: Color = .blue
    
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let normalizedValue = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            
            ZStack(alignment: .bottom) {
                // トラック背景
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.3))
                    .frame(width: 4)
                
                // アクティブ部分
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [trackColor.opacity(0.5), trackColor.opacity(0.9)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 4, height: height * normalizedValue)
                
                // サム（つまみ）
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(y: -(height * normalizedValue - 7))
            }
            .frame(maxWidth: .infinity)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let normalized = 1.0 - Float(drag.location.y / height)
                        let clamped = min(max(normalized, 0), 1)
                        value = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
                    }
            )
        }
    }
}
