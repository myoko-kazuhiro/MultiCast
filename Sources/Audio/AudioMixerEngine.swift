import Foundation
import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import os.log

/// AVAudioEngineベースのミキシングエンジン
/// 4入力チャンネル × 4出力バスのルーティングを管理
class AudioMixerEngine: ObservableObject {
    private let logger = AppLogger(category: "AudioMixerEngine")
    
    /// エンジンの状態
    @Published var state: EngineState = .stopped
    
    /// オーディオルート設定
    let audioRoute: AudioRoute
    
    /// メインのAVAudioEngine（各出力バス用）
    private var engines: [AVAudioEngine?] = Array(repeating: nil, count: 4)
    
    /// 各入力チャンネル用のソースノードとキャプチャラー
    private var sourceNodes: [[AVAudioSourceNode?]] = Array(repeating: Array(repeating: nil, count: 4), count: 4) // [input][output]
    private var capturers: [AudioInputCapturer?] = Array(repeating: nil, count: 4)
    
    /// 各出力バス用のミキサーノード
    private var mixerNodes: [AVAudioMixerNode?] = Array(repeating: nil, count: 4)
    private var limiterNodes: [AVAudioUnitEffect?] = Array(repeating: nil, count: 4)
    
    /// パンノード [入力index][出力バスindex] - SourceNodeとMainMixerの間に挿入
    private var eqNodes: [[AVAudioUnitEQ?]] = Array(repeating: Array(repeating: nil, count: 4), count: 4)
    private var panNodes: [[AVAudioMixerNode?]] = Array(repeating: Array(repeating: nil, count: 4), count: 4)
    
    /// コンプレッサーノード [入力index][出力バスindex]
    private var compressorNodes: [[AVAudioUnitEffect?]] = Array(repeating: Array(repeating: nil, count: 4), count: 4)
    
    /// レベルメーター用データ
    private let levelMeter = LevelMeter()
    
    /// シリアルキュー（エンジン操作の排他制御）
    private let engineQueue = DispatchQueue(label: "com.multicast.engine", qos: .userInteractive)
    
    /// リビルド中フラグ（設定変更通知による無限ループ防止）
    private(set) var isRebuilding = false
    
    /// Combine の購読保持用
    private var cancellables = Set<AnyCancellable>()
    
    /// レベルメーター用キャッシュ (30fpsで更新するため、スレッドセーフなポインタを利用)
    private let inputLevelsL = UnsafeMutablePointer<Float>.allocate(capacity: 4)
    private let inputLevelsR = UnsafeMutablePointer<Float>.allocate(capacity: 4)
    private let outputLevelsL = UnsafeMutablePointer<Float>.allocate(capacity: 4)
    private let outputLevelsR = UnsafeMutablePointer<Float>.allocate(capacity: 4)
    private var levelUpdateTimer: Timer?
    
    init(audioRoute: AudioRoute) {
        self.audioRoute = audioRoute
        for i in 0..<4 {
            inputLevelsL[i] = -120.0
            inputLevelsR[i] = -120.0
            outputLevelsL[i] = -120.0
            outputLevelsR[i] = -120.0
        }
        setupObservers()
    }
    
    deinit {
        inputLevelsL.deallocate()
        inputLevelsR.deallocate()
        outputLevelsL.deallocate()
        outputLevelsR.deallocate()
    }
    
    private func setupObservers() {
        // 入力チャンネル: ボリューム、ゲイン、パン、ルーティング、ミュート、ソロ、エフェクトパラメータの変更を個別に監視
        // levelL/levelR/peakL/peakR の変更は監視しない（フィードバックループ防止）
        for channel in audioRoute.inputChannels {
            // ボリューム系
            channel.$volume.combineLatest(channel.$gain, channel.$pan)
                .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.engineQueue.async { [weak self] in
                        self?.updateVolume(for: channel)
                    }
                }
                .store(in: &cancellables)
            
            // ミュート/ソロ/ルーティング
            channel.$isMuted.combineLatest(channel.$isSolo)
                .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.engineQueue.async { [weak self] in
                        self?.updateVolume(for: channel)
                    }
                }
                .store(in: &cancellables)
            
            channel.$routingToOutputs
                .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.engineQueue.async { [weak self] in
                        self?.updateVolume(for: channel)
                    }
                }
                .store(in: &cancellables)
            
            // エフェクトパラメータ
            channel.$compressorEnabled.combineLatest(channel.$compressorThreshold, channel.$compressorHeadRoom)
                .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.engineQueue.async { [weak self] in
                        self?.updateVolume(for: channel)
                    }
                }
                .store(in: &cancellables)
            
            channel.$compressorAttack.combineLatest(channel.$compressorRelease, channel.$compressorMakeupGain)
                .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.engineQueue.async { [weak self] in
                        self?.updateVolume(for: channel)
                    }
                }
                .store(in: &cancellables)
            
            channel.$noiseGateEnabled.combineLatest(channel.$noiseGateThreshold)
                .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.engineQueue.async { [weak self] in
                        self?.updateVolume(for: channel)
                    }
                }
                .store(in: &cancellables)
            
            channel.$eqEnabled.combineLatest(channel.$eqLowCutFrequency)
                .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.engineQueue.async { [weak self] in
                        self?.updateVolume(for: channel)
                    }
                }
                .store(in: &cancellables)
        }
        
        // 出力バス: ボリューム、ミュート、リミッターの変更を監視
        for bus in audioRoute.outputBuses {
            bus.$volume.combineLatest(bus.$isMuted, bus.$limiterEnabled)
                .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.engineQueue.async { [weak self] in
                        self?.updateVolume(for: bus)
                    }
                }
                .store(in: &cancellables)
        }
    }
    
    // MARK: - Engine Lifecycle
    
    /// エンジンを起動
    func start() {
        engineQueue.async { [weak self] in
            self?.startInternal()
        }
    }
    
    private func startInternal() {
        guard state != .running else { return }
        
        do {
            setupAudioGraph()
            
            for engine in engines {
                if let engine = engine {
                    engine.prepare()
                    try engine.start()
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.state = .running
                self?.startLevelTimer()
            }
            
            logger.info("Audio engine started successfully")
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.state = .error
            }
        }
    }
    
    /// エンジンを停止
    func stop() {
        engineQueue.async { [weak self] in
            self?.stopInternal()
        }
    }
    
    private func stopInternal() {
        // タップを解除
        removeAllTaps()
        
        // エンジンを停止
        for engine in engines {
            engine?.stop()
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.state = .stopped
            self?.stopLevelTimer()
        }
        
        logger.info("Audio engine stopped")
    }
    
    /// エンジンを再構築
    func rebuild() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isRebuilding else {
                self.logger.info("Rebuild already in progress, skipping")
                return
            }
            self.isRebuilding = true
            self.stopInternal()
            self.teardownAudioGraph()
            
            // デバイス切り替え時のハードウェア準備完了を待つため少し遅延させる
            self.engineQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                self.startInternal()
                // startInternal完了後、少し待ってからフラグを解除
                // （起動直後の設定変更通知を無視するため）
                self.engineQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.isRebuilding = false
                }
            }
        }
    }
    
    // MARK: - Audio Graph Setup
    
    /// オーディオグラフをセットアップ
    private func setupAudioGraph() {
        teardownAudioGraph()
        
        // 各出力バス用のエンジンを構築
        for (busIndex, bus) in audioRoute.outputBuses.enumerated() {
            guard bus.selectedDevice.id != 0 else { continue }
            
            let engine = AVAudioEngine()
            engines[busIndex] = engine
            
            // 🚨 重要: formatの取得や接続を行う前に、目的のデバイスをoutputNodeにセットする！
            // 後から変更するとAVAudioEngineの内部フォーマット不整合で無音になるバグを回避
            setOutputDevice(bus.selectedDevice.id, for: engine, busIndex: busIndex)
            
            let mixer = AVAudioMixerNode()
            engine.attach(mixer)
            mixerNodes[busIndex] = mixer
            
            let outputFormat = engine.outputNode.inputFormat(forBus: 0)
            
            // Peak Limiter Node
            let limDesc = AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            let limiter = AVAudioUnitEffect(audioComponentDescription: limDesc)
            limiterNodes[busIndex] = limiter
            engine.attach(limiter)
            
            // mixer -> limiter -> mainMixerNode -> outputNode
            // outputNodeへ直接繋ぐより、mainMixerNodeを経由する方がMac環境での安定性が高い
            engine.connect(mixer, to: limiter, format: outputFormat)
            engine.connect(limiter, to: engine.mainMixerNode, format: outputFormat)
            
            installOutputLevelTap(on: limiter, busIndex: busIndex)
            
            mixer.outputVolume = bus.effectiveVolume
            limiter.bypass = !bus.limiterEnabled
        }
        
        // 入力チャンネルのセットアップ
        setupInputChannels()
        
        logger.info("Audio graph setup complete")
    }
    
    /// 入力チャンネルをセットアップ
    private func setupInputChannels() {
        for (inputIndex, channel) in audioRoute.inputChannels.enumerated() {
            guard channel.selectedDevice.id != 0 else { continue }
            
            // 1. キャプチャラーを作成・開始
            guard let firstEngine = engines.compactMap({ $0 }).first else { continue }
            let format = firstEngine.outputNode.inputFormat(forBus: 0)
            
            let capturer = AudioInputCapturer(deviceID: channel.selectedDevice.id, channelIndex: inputIndex, engineFormat: format)
            capturer.gain = channel.effectiveGain
            capturers[inputIndex] = capturer
            
            if !capturer.start() {
                logger.error("Failed to start capturer for Ch \(inputIndex + 1)")
                continue
            }
            
            // 2. 各出力エンジン用の SourceNode + PanNode を作成してミキサーに接続
            for (busIndex, engine) in engines.enumerated() {
                guard let engine = engine, let mixer = mixerNodes[busIndex] else { continue }
                
                // SourceNode
                let sourceNode = AVAudioSourceNode(format: format, renderBlock: capturer.createRenderBlock(forOutputBus: busIndex))
                sourceNodes[inputIndex][busIndex] = sourceNode
                engine.attach(sourceNode)
                
                // EQNode (Low-Cut)
                let eqNode = AVAudioUnitEQ(numberOfBands: 1)
                eqNodes[inputIndex][busIndex] = eqNode
                engine.attach(eqNode)
                applyEQSettings(eqNode, channel: channel)
                
                // CompressorNode (kAudioUnitSubType_DynamicsProcessor)
                let compDesc = AudioComponentDescription(
                    componentType: kAudioUnitType_Effect,
                    componentSubType: kAudioUnitSubType_DynamicsProcessor,
                    componentManufacturer: kAudioUnitManufacturer_Apple,
                    componentFlags: 0,
                    componentFlagsMask: 0
                )
                let compressor = AVAudioUnitEffect(audioComponentDescription: compDesc)
                compressorNodes[inputIndex][busIndex] = compressor
                engine.attach(compressor)
                applyCompressorSettings(compressor, channel: channel)
                
                // PanNode
                let panNode = AVAudioMixerNode()
                panNodes[inputIndex][busIndex] = panNode
                engine.attach(panNode)
                panNode.pan = channel.pan
                
                // SourceNode → EQ → Compressor → PanNode → MainMixer
                engine.connect(sourceNode, to: eqNode, format: format)
                engine.connect(eqNode, to: compressor, format: format)
                engine.connect(compressor, to: panNode, format: format)
                engine.connect(panNode, to: mixer, fromBus: 0, toBus: inputIndex, format: format)
                
                if busIndex == engines.firstIndex(where: { $0 != nil }) {
                    installLevelTap(on: sourceNode, channelIndex: inputIndex)
                }
                
                // ボリュームを設定（ルーティング設定を反映）
                let isRouted = channel.routingToOutputs.indices.contains(busIndex) ? channel.routingToOutputs[busIndex] : false
                sourceNode.volume = isRouted ? channel.effectiveVolume : 0.0
            }
        }
    }
    
    /// オーディオグラフを破棄
    private func teardownAudioGraph() {
        removeAllTaps()
        
        // キャプチャラーを停止・破棄
        for capturer in capturers {
            capturer?.stop()
        }
        capturers = Array(repeating: nil, count: 4)
        
        for engine in engines {
            engine?.stop()
        }
        
        engines = Array(repeating: nil, count: 4)
        mixerNodes = Array(repeating: nil, count: 4)
        limiterNodes = Array(repeating: nil, count: 4)
        sourceNodes = Array(repeating: Array(repeating: nil, count: 4), count: 4)
        eqNodes = Array(repeating: Array(repeating: nil, count: 4), count: 4)
        panNodes = Array(repeating: Array(repeating: nil, count: 4), count: 4)
        compressorNodes = Array(repeating: Array(repeating: nil, count: 4), count: 4)
    }
    
    // MARK: - Device Configuration
    
    // 廃止: AVAudioEngineのinputNodeへの依存をなくしたため setInputDevice は削除
    
    /// 出力デバイスを設定し、Busに合わせて出力チャンネルをマッピングする
    func setOutputDevice(_ deviceID: AudioDeviceID, for engine: AVAudioEngine, busIndex: Int) {
        let outputNode = engine.outputNode
        guard let audioUnit = outputNode.audioUnit else {
            logger.error("Failed to get audioUnit for outputNode, deviceID: \(deviceID)")
            return
        }
        
        // 1. デバイスをセット
        var deviceIDVar = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDVar,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        
        if status != noErr {
            logger.error("Failed to set output device \(deviceID): \(status)")
            return
        }
        
        // 2. 出力デバイスのチャンネル数を取得
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &formatSize)
        
        guard formatStatus == noErr else { return }
        
        let outChannels = Int(format.mChannelsPerFrame)
        guard outChannels > 0 else { return }
        
        // 3. チャンネルマップを作成 (-1 はミュート・未接続)
        var channelMap = [Int32](repeating: -1, count: outChannels)
        let startDeviceChannel = busIndex * 2
        
        if startDeviceChannel + 1 < outChannels {
            // デバイスに十分なチャンネルがある場合 (例: 16chデバイスなら Bus Aは0/1, Bus Bは2/3...)
            channelMap[startDeviceChannel] = 0     // 左 (L)
            channelMap[startDeviceChannel + 1] = 1 // 右 (R)
        } else {
            // デバイスのチャンネル数が足りない場合 (例: 2chデバイスにBus Bを割り当てた場合)
            // 自動的に最初のチャンネルにフォールバックする
            if outChannels > 1 {
                channelMap[0] = 0
                channelMap[1] = 1
            } else {
                channelMap[0] = 0 // モノラルデバイス
            }
        }
        
        // 4. マップを適用
        let mapSize = UInt32(outChannels * MemoryLayout<Int32>.size)
        let mapStatus = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Global, 0, &channelMap, mapSize)
        
        if mapStatus != noErr {
            logger.error("Failed to set channel map for bus \(busIndex): \(mapStatus)")
        } else {
            logger.info("Bus \(busIndex): Mapped to output channels \(channelMap)")
        }
    }
    
    // MARK: - Volume & Routing Control
    
    /// チャンネルのボリューム/ゲイン/パンを更新
    func updateVolume(for channel: MixerChannel) {
        // エンジンが動作中でなければ何もしない（teardown中のノードアクセスを防止）
        guard state == .running else { return }
        guard !mixerNodes.isEmpty else { return }
        
        switch channel.channelType {
        case .input:
            let inputIndex = channel.id
            guard inputIndex < sourceNodes.count else { return }
            
            // ゲインをキャプチャラーに反映
            capturers[inputIndex]?.gain = channel.effectiveGain
            
            let effectiveVolume = audioRoute.isEffectivelyMuted(channel) ? 0.0 : channel.volume
            
            for busIndex in 0..<4 {
                if let sourceNode = sourceNodes[inputIndex][busIndex] {
                    let isRouted = channel.routingToOutputs.indices.contains(busIndex) ? channel.routingToOutputs[busIndex] : false
                    sourceNode.volume = isRouted ? effectiveVolume : 0.0
                }
                // パンをPanNodeに反映
                panNodes[inputIndex][busIndex]?.pan = channel.pan
                // EQパラメータを更新
                if let eq = eqNodes[inputIndex][busIndex] {
                    applyEQSettings(eq, channel: channel)
                }
                // コンプレッサーパラメータを更新
                if let comp = compressorNodes[inputIndex][busIndex] {
                    applyCompressorSettings(comp, channel: channel)
                }
            }
            
        case .output:
            let busIndex = channel.id
            if busIndex < mixerNodes.count, let mixer = mixerNodes[busIndex] {
                mixer.outputVolume = channel.effectiveVolume
            }
            if busIndex < limiterNodes.count, let limiter = limiterNodes[busIndex] {
                limiter.bypass = !channel.limiterEnabled
            }
        }
    }
    
    /// コンプレッサー設定を適用
    private func applyCompressorSettings(_ comp: AVAudioUnitEffect, channel: MixerChannel) {
        // コンプレッサーまたはノイズゲートのいずれかが有効ならBypass解除
        let isAnyDynamicsEnabled = channel.compressorEnabled || channel.noiseGateEnabled
        comp.bypass = !isAnyDynamicsEnabled
        
        let au = comp.audioUnit
        
        // --- Compressor ---
        if channel.compressorEnabled {
            AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, channel.compressorThreshold, 0)
            AudioUnitSetParameter(au, 1, kAudioUnitScope_Global, 0, channel.compressorHeadRoom, 0)
            AudioUnitSetParameter(au, 4, kAudioUnitScope_Global, 0, channel.compressorAttack, 0)
            AudioUnitSetParameter(au, 5, kAudioUnitScope_Global, 0, channel.compressorRelease, 0)
            AudioUnitSetParameter(au, 6, kAudioUnitScope_Global, 0, channel.compressorMakeupGain, 0)
        } else {
            // オフ時はスルーする設定
            AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, -20.0, 0)
            AudioUnitSetParameter(au, 1, kAudioUnitScope_Global, 0, 40.0, 0) // Max HeadRoom (Ratio 1:1)
            AudioUnitSetParameter(au, 6, kAudioUnitScope_Global, 0, 0.0, 0)
        }
        
        // --- Noise Gate (Expander) ---
        if channel.noiseGateEnabled {
            AudioUnitSetParameter(au, 3, kAudioUnitScope_Global, 0, channel.noiseGateThreshold, 0) // ExpansionThreshold
            AudioUnitSetParameter(au, 2, kAudioUnitScope_Global, 0, 50.0, 0) // ExpansionRatio (Steep)
        } else {
            // オフ時は完全にスルーする設定
            AudioUnitSetParameter(au, 3, kAudioUnitScope_Global, 0, -100.0, 0)
            AudioUnitSetParameter(au, 2, kAudioUnitScope_Global, 0, 1.0, 0)
        }
    }
    
    /// EQ設定を適用
    private func applyEQSettings(_ eq: AVAudioUnitEQ, channel: MixerChannel) {
        guard !eq.bands.isEmpty else { return }
        let band = eq.bands[0]
        if channel.eqEnabled {
            band.filterType = .highPass
            band.frequency = channel.eqLowCutFrequency
            band.bypass = false
        } else {
            band.bypass = true
        }
    }
    
    // MARK: - Level Metering
    
    /// レベルメーター用タップを設置
    private func installLevelTap(on node: AVAudioNode, channelIndex: Int) {
        let format = node.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        
        let bufferSize: AVAudioFrameCount = 1024
        
        node.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self = self, channelIndex < 4 else { return }
            let levels = self.levelMeter.calculateLevels(buffer: buffer)
            self.inputLevelsL[channelIndex] = levels.left
            self.inputLevelsR[channelIndex] = levels.right
        }
    }
    
    /// 出力バス用レベルメータータップを設置
    private func installOutputLevelTap(on node: AVAudioNode, busIndex: Int) {
        let format = node.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        
        let bufferSize: AVAudioFrameCount = 1024
        
        node.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self = self, busIndex < 4 else { return }
            let levels = self.levelMeter.calculateLevels(buffer: buffer)
            self.outputLevelsL[busIndex] = levels.left
            self.outputLevelsR[busIndex] = levels.right
        }
    }
    
    // MARK: - Level Timer
    
    private func startLevelTimer() {
        stopLevelTimer()
        levelUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updatePublishedLevels()
        }
    }
    
    private func stopLevelTimer() {
        levelUpdateTimer?.invalidate()
        levelUpdateTimer = nil
    }
    
    private func updatePublishedLevels() {
        for (i, channel) in audioRoute.inputChannels.enumerated() where i < 4 {
            let left = inputLevelsL[i]
            let right = inputLevelsR[i]
            channel.levelL = left
            channel.levelR = right
            channel.peakL = max(channel.peakL, left)
            channel.peakR = max(channel.peakR, right)
        }
        for (i, bus) in audioRoute.outputBuses.enumerated() where i < 4 {
            let left = outputLevelsL[i]
            let right = outputLevelsR[i]
            bus.levelL = left
            bus.levelR = right
            bus.peakL = max(bus.peakL, left)
            bus.peakR = max(bus.peakR, right)
        }
    }
    
    /// すべてのタップを解除
    func removeAllTaps() {
        for row in sourceNodes {
            for node in row.compactMap({ $0 }) {
                node.removeTap(onBus: 0)
            }
        }
        for row in panNodes {
            for node in row.compactMap({ $0 }) {
                node.removeTap(onBus: 0)
            }
        }
        for node in mixerNodes.compactMap({ $0 }) {
            node.removeTap(onBus: 0)
        }
    }
    
    // MARK: - Channel Configuration
    
    /// 入力チャンネルのデバイスを変更
    func changeInputDevice(channelIndex: Int, device: AudioDevice) {
        guard channelIndex < audioRoute.inputChannels.count else { return }
        let channel = audioRoute.inputChannels[channelIndex]
        
        let oldUID = channel.selectedDeviceUID
        channel.selectedDevice = device
        channel.selectedDeviceUID = device.uid
        
        // デバイスが変わっていない場合は何もしない
        if oldUID == device.uid { return }
        
        // デバイス変更時は入力レベルとピークをリセット
        DispatchQueue.main.async {
            channel.levelL = -Float.infinity
            channel.levelR = -Float.infinity
            channel.peakL = -Float.infinity
            channel.peakR = -Float.infinity
        }
        
        // エンジンを再構築して新しいデバイスを反映
        rebuild()
    }
    
    /// 出力バスのデバイスを変更
    func changeOutputDevice(busIndex: Int, device: AudioDevice) {
        guard busIndex < audioRoute.outputBuses.count else { return }
        let bus = audioRoute.outputBuses[busIndex]
        
        let oldUID = bus.selectedDeviceUID
        bus.selectedDevice = device
        bus.selectedDeviceUID = device.uid
        
        // デバイスが変わっていない場合は何もしない
        if oldUID == device.uid { return }
        
        // エンジンを再構築して新しいデバイスを反映
        rebuild()
    }
    
    // MARK: - Peak Reset
    
    /// ピークホールドをリセット
    func resetPeaks() {
        for channel in audioRoute.inputChannels {
            channel.peakL = -Float.infinity
            channel.peakR = -Float.infinity
        }
        for bus in audioRoute.outputBuses {
            bus.peakL = -Float.infinity
            bus.peakR = -Float.infinity
        }
    }
}

/// エンジンの状態
enum EngineState: String {
    case stopped        // 初期状態 or 明示的停止
    case running        // 正常動作中
    case suspended      // スリープ中（意図的停止）
    case recovering     // リカバリ処理中
    case error          // リカバリ失敗
    
    var displayName: String {
        switch self {
        case .stopped: return "停止"
        case .running: return "動作中"
        case .suspended: return "一時停止"
        case .recovering: return "復帰中..."
        case .error: return "エラー"
        }
    }
    
    var isHealthy: Bool {
        self == .running
    }
}
