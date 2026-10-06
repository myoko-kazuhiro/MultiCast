import SwiftUI

/// メインウィンドウのレイアウト
struct ContentView: View {
    @ObservedObject var audioRoute: AudioRoute
    @ObservedObject var mixerEngine: AudioMixerEngine
    @ObservedObject var deviceManager: AudioDeviceManager
    
    /// 現在コンプレッサーパネルを表示中の入力チャンネル (nil = 非表示)
    @State private var selectedCompressorChannel: Int? = nil
    
    var body: some View {
        HStack(spacing: 0) {
            // メインコンテンツエリア
            VStack(spacing: 0) {
                // ステータスバー
                statusBar
                
                Divider()
                    .background(Color(white: 0.3))
                
                // メインコンテンツ
                VStack(spacing: 12) {
                    // 入力チャンネルセクション
                    inputSection
                    
                    // ルーティングマトリクス
                    routingSection
                    
                    // 出力バスセクション
                    outputSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .frame(width: 592) // 幅は固定(544 + 左右24 = 592)、高さはコンテンツサイズに自動フィットさせる
            
            // 右側インスペクターパネル
            if let idx = selectedCompressorChannel, idx < audioRoute.inputChannels.count {
                Divider()
                    .background(Color(white: 0.3))
                
                InspectorView(
                    audioRoute: audioRoute,
                    channel: audioRoute.inputChannels[idx],
                    selectedChannelIndex: Binding(
                        get: { selectedCompressorChannel },
                        set: { selectedCompressorChannel = $0 }
                    ),
                    onClose: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            selectedCompressorChannel = nil
                        }
                    }
                )
                .frame(width: 280)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Color(white: 0.12))
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Status Bar
    
    private var statusBar: some View {
        VStack(spacing: 0) {
            // macOS の hiddenTitleBar 使用時に信号機ボタンのための余白領域
            Color.clear
                .frame(height: 12)
            
            HStack(spacing: 12) {
                // アプリロゴ / 名前 (左に寄せる)
                HStack(spacing: 6) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.cyan, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text("MultiCast")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                // エンジン状態インジケーター
                HStack(spacing: 6) {
                    Circle()
                        .fill(engineStatusColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: engineStatusColor.opacity(0.6), radius: 3)
                    
                    Text(mixerEngine.state.displayName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                // リカバリボタン（エラー時のみ表示）
                if mixerEngine.state == .error {
                    Button("再接続") {
                        mixerEngine.rebuild()
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
                
                // ピークリセットボタン
                Button(action: { mixerEngine.resetPeaks() }) {
                    Text("Peak Reset")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(white: 0.2))
                .cornerRadius(4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(Color(white: 0.08))
    }
    
    // MARK: - Input Section
    
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title: "INPUT CHANNELS", icon: "mic.fill")
            
            HStack(spacing: 8) {
                ForEach(audioRoute.inputChannels) { channel in
                    InputChannelView(
                        channel: channel,
                        deviceManager: deviceManager,
                        outputBusCount: 4,
                        isCompressorSelected: selectedCompressorChannel == channel.id,
                        onDeviceChanged: { device in
                            mixerEngine.changeInputDevice(channelIndex: channel.id, device: device)
                        },
                        onCompressorToggle: {
                            if selectedCompressorChannel == channel.id {
                                selectedCompressorChannel = nil
                            } else {
                                selectedCompressorChannel = channel.id
                            }
                        }
                    )
                }
            }
            
        }
    }
    
    // MARK: - Routing Section
    
    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title: "ROUTING MATRIX", icon: "arrow.triangle.branch")
            
            RoutingMatrixView(audioRoute: audioRoute)
        }
    }
    
    // MARK: - Output Section
    
    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title: "OUTPUT BUSES", icon: "speaker.wave.3.fill")
            
            HStack(spacing: 8) {
                ForEach(audioRoute.outputBuses) { channel in
                    OutputBusView(
                        channel: channel,
                        deviceManager: deviceManager,
                        onDeviceChanged: { device in
                            mixerEngine.changeOutputDevice(busIndex: channel.id, device: device)
                        }
                    )
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.cyan.opacity(0.7))
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.gray)
        }
    }
    
    private var engineStatusColor: Color {
        switch mixerEngine.state {
        case .running:    return .green
        case .stopped:    return .gray
        case .suspended:  return .yellow
        case .recovering: return .orange
        case .error:      return .red
        }
    }
}

#Preview {
    ContentView(
        audioRoute: AudioRoute(),
        mixerEngine: AudioMixerEngine(audioRoute: AudioRoute()),
        deviceManager: AudioDeviceManager.shared
    )
}

/// 選択されたチャンネルの詳細設定を行う右サイドバー（インスペクター）
struct InspectorView: View {
    @ObservedObject var audioRoute: AudioRoute
    @ObservedObject var channel: MixerChannel
    @Binding var selectedChannelIndex: Int?
    var onClose: () -> Void
    
    private let hues: [Double] = [0.55, 0.35, 0.12, 0.8]
    private var accentColor: Color {
        let hue = channel.id < hues.count ? hues[channel.id] : 0.5
        return Color(hue: hue, saturation: 0.7, brightness: 0.85)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Text("Inspector")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(accentColor)
                
                Spacer()
                
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color(white: 0.6))
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color(white: 0.15))
            
            // チャンネル切り替えタブ
            Picker("Channel", selection: $selectedChannelIndex) {
                ForEach(audioRoute.inputChannels) { ch in
                    let name = ch.customName
                    Text(name.isEmpty ? "In \(ch.id + 1)" : name).tag(ch.id as Int?)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(white: 0.15))
            
            ScrollView {
                VStack(spacing: 16) {
                    // グローバルプリセットセクション
                    presetSection
                    
                    // ノイズゲート
                    noiseGateSection
                    
                    // EQ (ローカット)
                    eqSection
                    
                    // コンプレッサー
                    compressorSection
                }
                .padding(16)
            }
        }
        .background(Color(white: 0.1).edgesIgnoringSafeArea(.all))
    }
    
    // MARK: - Sections
    
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GLOBAL PRESETS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
            
            Menu {
                Button("FPS (足音強調)") { applyGlobalPreset("fps") }
                Button("VC (ボイスチャット)") { applyGlobalPreset("vc") }
                Button("Cinema (映画)") { applyGlobalPreset("cinema") }
                Button("Clean Mic (ノイズ除去)") { applyGlobalPreset("clean_mic") }
                Button("Reset All") { applyGlobalPreset("reset") }
            } label: {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("Select Effect Chain Preset...")
                    Spacer()
                }
                .padding(8)
                .background(Color(white: 0.2))
                .cornerRadius(6)
            }
            .menuStyle(.borderlessButton)
        }
    }
    
    private var noiseGateSection: some View {
        DisclosureGroup(
            isExpanded: .constant(true),
            content: {
                VStack(spacing: 12) {
                    HStack {
                        Text("Threshold")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.1f dBFS", channel.noiseGateThreshold))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                    Slider(value: $channel.noiseGateThreshold, in: -80...0)
                        .tint(Color.orange)
                        .disabled(!channel.noiseGateEnabled)
                }
                .padding(.top, 8)
                .opacity(channel.noiseGateEnabled ? 1.0 : 0.5)
            },
            label: {
                Toggle("Noise Gate", isOn: $channel.noiseGateEnabled)
                    .font(.system(size: 13, weight: .bold))
                    .tint(.orange)
            }
        )
        .padding()
        .background(Color(white: 0.15).cornerRadius(8))
    }
    
    private var eqSection: some View {
        DisclosureGroup(
            isExpanded: .constant(true),
            content: {
                VStack(spacing: 12) {
                    HStack {
                        Text("Cutoff")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.0f Hz", channel.eqLowCutFrequency))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                    Slider(value: $channel.eqLowCutFrequency, in: 20...500)
                        .tint(Color.cyan)
                        .disabled(!channel.eqEnabled)
                }
                .padding(.top, 8)
                .opacity(channel.eqEnabled ? 1.0 : 0.5)
            },
            label: {
                Toggle("Low-Cut EQ", isOn: $channel.eqEnabled)
                    .font(.system(size: 13, weight: .bold))
                    .tint(.cyan)
            }
        )
        .padding()
        .background(Color(white: 0.15).cornerRadius(8))
    }
    
    private var compressorSection: some View {
        DisclosureGroup(
            isExpanded: .constant(true),
            content: {
                VStack(spacing: 12) {
                    InspectorSliderRow(label: "Thr.", unit: "dB", value: $channel.compressorThreshold, range: -40...0, color: Color(hue: 0.0, saturation: 0.7, brightness: 0.85))
                    InspectorSliderRow(label: "Ratio", unit: "", value: $channel.compressorHeadRoom, range: 0.1...40.0, color: Color(hue: 0.8, saturation: 0.7, brightness: 0.85))
                    InspectorSliderRow(
                        label: "Attack",
                        unit: "ms",
                        value: Binding(get: { channel.compressorAttack * 1000 }, set: { channel.compressorAttack = $0 / 1000 }),
                        range: 1...200,
                        color: Color(hue: 0.55, saturation: 0.7, brightness: 0.85)
                    )
                    InspectorSliderRow(
                        label: "Release",
                        unit: "ms",
                        value: Binding(get: { channel.compressorRelease * 1000 }, set: { channel.compressorRelease = $0 / 1000 }),
                        range: 10...3000,
                        color: Color(hue: 0.35, saturation: 0.7, brightness: 0.85)
                    )
                    InspectorSliderRow(label: "Makeup", unit: "dB", value: $channel.compressorMakeupGain, range: 0...40, color: Color(hue: 0.13, saturation: 0.8, brightness: 0.9))
                }
                .padding(.top, 8)
                .opacity(channel.compressorEnabled ? 1.0 : 0.5)
            },
            label: {
                Toggle("Compressor", isOn: $channel.compressorEnabled)
                    .font(.system(size: 13, weight: .bold))
                    .tint(.green)
            }
        )
        .padding()
        .background(Color(white: 0.15).cornerRadius(8))
    }
    
    // MARK: - Global Presets Logic
    
    private func applyGlobalPreset(_ preset: String) {
        withAnimation(.easeInOut(duration: 0.3)) {
            switch preset {
            case "fps":
                // ゲートを少し強めにして環境ノイズをカット
                channel.noiseGateEnabled = true
                channel.noiseGateThreshold = -38.0
                // EQで無駄な低音・環境音カット（足音にフォーカス）
                channel.eqEnabled = true
                channel.eqLowCutFrequency = 150.0
                // コンプレッサー（ノイズを持ち上げすぎないように調整）
                channel.compressorEnabled = true
                channel.compressorThreshold = -22.0
                channel.compressorHeadRoom = 5.0
                channel.compressorAttack = 0.010
                channel.compressorRelease = 0.150
                channel.compressorMakeupGain = 4.0
                
            case "vc":
                channel.noiseGateEnabled = true
                channel.noiseGateThreshold = -35.0
                channel.eqEnabled = true
                channel.eqLowCutFrequency = 80.0
                
                channel.compressorEnabled = true
                channel.compressorThreshold = -20.0
                channel.compressorHeadRoom = 5.0
                channel.compressorAttack = 0.010
                channel.compressorRelease = 0.200
                channel.compressorMakeupGain = 6.0
                
            case "clean_mic":
                channel.noiseGateEnabled = true
                channel.noiseGateThreshold = -30.0
                channel.eqEnabled = true
                channel.eqLowCutFrequency = 100.0
                
                channel.compressorEnabled = false
                
            case "cinema":
                channel.noiseGateEnabled = false
                channel.eqEnabled = true
                channel.eqLowCutFrequency = 40.0
                
                channel.compressorEnabled = true
                channel.compressorThreshold = -25.0
                channel.compressorHeadRoom = 15.0
                channel.compressorAttack = 0.020
                channel.compressorRelease = 0.500
                channel.compressorMakeupGain = 4.0
                
            case "reset":
                channel.noiseGateEnabled = false
                channel.eqEnabled = false
                channel.compressorEnabled = false
                
            default: break
            }
        }
    }
}

private struct InspectorSliderRow: View {
    let label: String
    let unit: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var color: Color = .blue
    
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: unit.isEmpty ? "%.1f" : "%.1f \(unit)", value))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(color)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(color)
        }
    }
}
