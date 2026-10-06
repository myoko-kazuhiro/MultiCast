import SwiftUI

/// 入力チャンネル用コンプレッサーパネル（折りたたみ可能）
struct CompressorPanel: View {
    @ObservedObject var channel: MixerChannel
    @State private var isExpanded: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー（折りたたみトグル）
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    // COMP ON/OFF ボタン
                    Text("COMP")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(channel.compressorEnabled ? .black : Color(white: 0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(channel.compressorEnabled
                                      ? Color(hue: 0.13, saturation: 0.9, brightness: 0.95)
                                      : Color(white: 0.25))
                        )
                        .onTapGesture { channel.compressorEnabled.toggle() }
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Color(white: 0.5))
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(Color(white: 0.12).cornerRadius(5))
            }
            .buttonStyle(.plain)
            
            // パラメータパネル（展開時のみ表示）
            if isExpanded {
                VStack(spacing: 6) {
                    // Threshold
                    CompressorParamRow(
                        label: "THR",
                        value: $channel.compressorThreshold,
                        range: -40...0,
                        unit: "dB",
                        format: "%.0f",
                        color: Color(hue: 0.0, saturation: 0.7, brightness: 0.85)
                    )
                    
                    // Attack
                    CompressorParamRow(
                        label: "ATK",
                        value: Binding(
                            get: { channel.compressorAttack * 1000 }, // 秒→ms表示
                            set: { channel.compressorAttack = $0 / 1000 }
                        ),
                        range: 1...200,
                        unit: "ms",
                        format: "%.0f",
                        color: Color(hue: 0.55, saturation: 0.7, brightness: 0.85)
                    )
                    
                    // Release
                    CompressorParamRow(
                        label: "REL",
                        value: Binding(
                            get: { channel.compressorRelease * 1000 }, // 秒→ms表示
                            set: { channel.compressorRelease = $0 / 1000 }
                        ),
                        range: 10...3000,
                        unit: "ms",
                        format: "%.0f",
                        color: Color(hue: 0.35, saturation: 0.7, brightness: 0.85)
                    )
                    
                    // Makeup Gain
                    CompressorParamRow(
                        label: "MKP",
                        value: $channel.compressorMakeupGain,
                        range: 0...40,
                        unit: "dB",
                        format: "+%.0f",
                        color: Color(hue: 0.13, saturation: 0.8, brightness: 0.9)
                    )
                }
                .padding(6)
                .background(Color(white: 0.10).cornerRadius(5))
            }
        }
    }
}

/// コンプレッサーの各パラメータ行
private struct CompressorParamRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let unit: String
    let format: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 26, alignment: .leading)
            
            Slider(value: $value, in: range)
                .controlSize(.mini)
                .tint(color)
            
            Text(String(format: format, value) + unit)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(Color(white: 0.65))
                .frame(width: 34, alignment: .trailing)
                .lineLimit(1)
        }
    }
}
