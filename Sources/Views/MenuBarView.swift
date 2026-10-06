import SwiftUI

/// メニューバー常駐のステータスアイテム
struct MenuBarView: View {
    @ObservedObject var mixerEngine: AudioMixerEngine
    @ObservedObject var audioRoute: AudioRoute
    
    /// エラーログウィンドウを表示するコールバック
    var onOpenLogs: (() -> Void)?
    
    /// メインウィンドウを表示するコールバック
    var onShowMainWindow: (() -> Void)?
    
    /// アプリ終了のコールバック
    var onQuit: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(.cyan)
                Text("MultiCast")
                    .font(.system(size: 13, weight: .bold))
                
                Spacer()
                
                // エンジン状態
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(mixerEngine.state.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            Divider()
            
            // 入力チャンネルのクイックビュー
            ForEach(audioRoute.inputChannels) { channel in
                menuBarChannelRow(channel: channel, type: "In")
            }
            
            Divider()
            
            // 出力バスのクイックビュー
            ForEach(audioRoute.outputBuses) { channel in
                menuBarChannelRow(channel: channel, type: "Out")
            }
            
            Divider()
            
            // アクションボタン
            Button("エラーログを表示") {
                onOpenLogs?()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            
            Button("メインウィンドウを表示") {
                onShowMainWindow?()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            
            Button("終了") {
                onQuit?()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 280)
    }
    
    private func menuBarChannelRow(channel: MixerChannel, type: String) -> some View {
        HStack(spacing: 8) {
            Text("\(type) \(channel.id + 1)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)
            
            Text(channel.selectedDevice.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            
            Spacer()
            
            // ミュートインジケーター
            if channel.isMuted {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
            
            // レベルインジケーター（簡易）
            StereoLevelMeterView(
                levelL: channel.levelL,
                levelR: channel.levelR,
                peakL: channel.peakL,
                peakR: channel.peakR,
                orientation: .horizontal,
                thickness: 3
            )
            .frame(width: 50)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
    
    private var statusColor: Color {
        switch mixerEngine.state {
        case .running:    return .green
        case .stopped:    return .gray
        case .suspended:  return .yellow
        case .recovering: return .orange
        case .error:      return .red
        }
    }
}
