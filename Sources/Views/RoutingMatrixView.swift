import SwiftUI

/// 4×4 ルーティングマトリクスの表示コンポーネント
struct RoutingMatrixView: View {
    @ObservedObject var audioRoute: AudioRoute
    
    var body: some View {
        VStack(spacing: 8) {
            // ヘッダー行
            HStack(spacing: 8) {
                // 左上空白セル
                Text("")
                    .frame(width: 80, height: 32)
                
                // 出力バスラベル（デバイス名含む）
                ForEach(0..<4, id: \.self) { col in
                    RoutingMatrixHeaderCellView(
                        bus: audioRoute.outputBuses[col],
                        colIndex: col,
                        outputHue: outputHue(col)
                    )
                }
            }
            .padding(.horizontal, 20)
            
            // マトリクス行（各行を独立したサブビューで管理）
            ForEach(audioRoute.inputChannels) { channel in
                RoutingMatrixRowView(
                    channel: channel,
                    rowIndex: channel.id,
                    inputHue: inputHue(channel.id)
                )
            }
        }
        .padding(.vertical, 16)
        .frame(width: 544) // Input/Output セクションの幅 (130*4 + 8*3 = 544) と外枠を揃える
        .background(
            RoutingLinesOverlay(audioRoute: audioRoute)
        )
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(white: 0.22), lineWidth: 1)
        )
    }
    
    private func inputHue(_ index: Int) -> Double {
        let hues: [Double] = [0.55, 0.35, 0.12, 0.8]
        return index < hues.count ? hues[index] : 0.5
    }
    
    private func outputHue(_ index: Int) -> Double {
        let hues: [Double] = [0.6, 0.45, 0.3, 0.75]
        return index < hues.count ? hues[index] : 0.5
    }
}

/// マトリクスの1行（1入力チャンネル分）
/// MixerChannel を直接 @ObservedObject で監視するため、
/// routingToOutputs の変更を確実に検知して再描画できる
struct RoutingMatrixRowView: View {
    @ObservedObject var channel: MixerChannel
    let rowIndex: Int
    let inputHue: Double
    
    var body: some View {
        HStack(spacing: 8) {
            // 入力チャンネルラベル（デバイス名含む）
            VStack(spacing: 2) {
                Text("In \(rowIndex + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(hue: inputHue, saturation: 0.6, brightness: 0.9))
                Text(channel.selectedDevice.id == 0 ? "(なし)" : channel.selectedDevice.name)
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 80, height: 32)
            
            // ルーティングセル
            ForEach(0..<4, id: \.self) { col in
                RoutingCellView(
                    isActive: Binding(
                        get: {
                            guard col < channel.routingToOutputs.count else { return false }
                            return channel.routingToOutputs[col]
                        },
                        set: { newValue in
                            guard col < channel.routingToOutputs.count else { return }
                            channel.routingToOutputs[col] = newValue
                        }
                    ),
                    inputIndex: rowIndex,
                    outputIndex: col
                )
            }
        }
        .padding(.horizontal, 20)
    }
}

/// ルーティングマトリクスの個別セル
struct RoutingCellView: View {
    @Binding var isActive: Bool
    let inputIndex: Int
    let outputIndex: Int
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: { isActive.toggle() }) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(cellBackgroundColor)
                    .frame(width: 98, height: 28)
                
                if isActive {
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
                
                RoundedRectangle(cornerRadius: 4)
                    .stroke(cellBorderColor, lineWidth: 1)
                    .frame(width: 98, height: 28)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 98, height: 32)
        .onHover { hovering in
            isHovering = hovering
        }
    }
    
    private var cellBackgroundColor: Color {
        if isActive {
            return Color(hue: 0.58, saturation: 0.7, brightness: isHovering ? 0.7 : 0.55).opacity(0.8)
        }
        return (isHovering ? Color(white: 0.25) : Color(white: 0.18)).opacity(0.6)
    }
    
    private var cellBorderColor: Color {
        if isActive {
            return Color(hue: 0.58, saturation: 0.5, brightness: 0.8)
        }
        return Color(white: 0.3)
    }
}

/// マトリクスの出力バスラベル（ヘッダー）
struct RoutingMatrixHeaderCellView: View {
    @ObservedObject var bus: MixerChannel
    let colIndex: Int
    let outputHue: Double
    
    var body: some View {
        VStack(spacing: 2) {
            Text("Out \(colIndex + 1)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hue: outputHue, saturation: 0.5, brightness: 0.9))
            Text(bus.selectedDevice.id == 0 ? "(なし)" : bus.selectedDevice.name)
                .font(.system(size: 9))
                .foregroundColor(.gray)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 98, height: 32)
    }
}

/// 接続状態を線で描画するオーバーレイ
struct RoutingLinesOverlay: View {
    @ObservedObject var audioRoute: AudioRoute
    
    var body: some View {
        ZStack {
            ForEach(audioRoute.inputChannels) { channel in
                RoutingLineRow(channel: channel)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 1つの入力チャンネルからの接続線を描画
struct RoutingLineRow: View {
    @ObservedObject var channel: MixerChannel
    
    var body: some View {
        Canvas { context, size in
            let r = channel.id
            for c in 0..<min(channel.routingToOutputs.count, 4) {
                if channel.routingToOutputs[c] {
                    drawLine(context: &context, r: r, c: c)
                }
            }
        }
    }
    
    private func drawLine(context: inout GraphicsContext, r: Int, c: Int) {
        // 重なりを防ぐためのオフセット（r=行, c=列）
        // 垂直線は行(r)ごとにX座標をずらす
        let xOffset = (CGFloat(r) - 1.5) * 6
        // 水平線は列(c)ごとにY座標をずらす
        let yOffset = (CGFloat(c) - 1.5) * 6
        
        let x = CGFloat(157 + c * 106) + xOffset
        let y = CGFloat(72 + r * 40) + yOffset
        let startX: CGFloat = 100
        let endY: CGFloat = 48
        
        var path = Path()
        path.move(to: CGPoint(x: startX, y: y))
        
        let cornerRadius: CGFloat = 4
        path.addLine(to: CGPoint(x: x - cornerRadius, y: y))
        path.addQuadCurve(to: CGPoint(x: x, y: y - cornerRadius), control: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x, y: endY))
        
        let hueIn = inputHue(r)
        let colorIn = Color(hue: hueIn, saturation: 0.8, brightness: 0.9)
        
        context.stroke(
            path,
            with: .color(colorIn),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )
    }
    
    private func inputHue(_ index: Int) -> Double {
        let hues: [Double] = [0.55, 0.35, 0.12, 0.8]
        return index < hues.count ? hues[index] : 0.5
    }
    
    private func outputHue(_ index: Int) -> Double {
        let hues: [Double] = [0.6, 0.45, 0.3, 0.75]
        return index < hues.count ? hues[index] : 0.5
    }
}
