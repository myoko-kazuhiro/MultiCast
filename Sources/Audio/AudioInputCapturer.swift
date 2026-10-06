import Foundation
import CoreAudio
import AVFoundation
import os.log

/// Core Audio (HAL) を用いて入力をキャプチャし、AVAudioConverterで高音質化してミキサーに渡すクラス
class AudioInputCapturer {
    private let logger = AppLogger(category: "AudioInputCapturer")
    
    let deviceID: AudioDeviceID
    let channelIndex: Int
    let engineFormat: AVAudioFormat
    
    // CoreAudio
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    
    /// ゲイン（リアルタイムスレッドからアトミックに書き込み可能）
    var gain: Float = 1.0
    
    // リングバッファ (出力バス 4 × L,R 2 = 8個)
    private let ringBuffersPointer: UnsafeMutablePointer<TPCircularBuffer>
    private let numOutputBuses = 4
    private let channelsPerBus = 2
    private var totalBuffers: Int { numOutputBuses * channelsPerBus }
    private var maxFramesToKeep: Int32 = 0
    private var frameCountForLog: Int = 0
    
    // フォーマット変換
    private(set) var deviceFormat: AudioStreamBasicDescription?
    private var avDeviceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    
    // 再利用可能なバッファ (リアルタイムスレッドでのアロケーションを避けるため)
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private let bufferCapacity: AVAudioFrameCount = 4096
    
    init(deviceID: AudioDeviceID, channelIndex: Int, engineFormat: AVAudioFormat) {
        self.deviceID = deviceID
        self.channelIndex = channelIndex
        self.engineFormat = engineFormat
        
        self.ringBuffersPointer = UnsafeMutablePointer<TPCircularBuffer>.allocate(capacity: 8) // 4 buses * 2 channels
        let bufferSize: Int32 = 256 * 1024 // 約0.5秒分
        for i in 0..<8 {
            TPCircularBufferInit(&ringBuffersPointer[i], bufferSize)
        }
        
        maxFramesToKeep = Int32(engineFormat.sampleRate * 0.1) // 100msレイテンシ制御
        setupFormatAndConverter()
    }
    
    deinit {
        stop()
        for i in 0..<totalBuffers {
            TPCircularBufferCleanup(&ringBuffersPointer[i])
        }
        ringBuffersPointer.deallocate()
    }
    
    // MARK: - Setup
    
    private func setupFormatAndConverter() {
        // 1. デバイスフォーマットの取得
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format)
        guard status == noErr else {
            logger.error("Ch \(self.channelIndex): Failed to get device format: \(status)")
            return
        }
        
        self.deviceFormat = format
        
        // 2. AVAudioFormat の作成
        var devFormat = AVAudioFormat(streamDescription: &format)
        
        if devFormat == nil {
            // マルチチャンネル（16ch等）で失敗した場合のフォールバック
            let layoutTag = kAudioChannelLayoutTag_DiscreteInOrder | format.mChannelsPerFrame
            if let layout = AVAudioChannelLayout(layoutTag: layoutTag) {
                let isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
                devFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.mSampleRate, interleaved: isInterleaved, channelLayout: layout)
            }
        }
        
        guard let validDevFormat = devFormat else {
            logger.error("Ch \(self.channelIndex): Failed to create AVAudioFormat from ASBD")
            return
        }
        self.avDeviceFormat = validDevFormat
        
        // 3. Converter と Buffer の作成
        if let conv = AVAudioConverter(from: validDevFormat, to: engineFormat) {
            
            // チャンネルマップの設定（これがないと多チャンネルデバイスでダウンミックスされず無音になる場合がある）
            let inChannels = Int(format.mChannelsPerFrame)
            let startDeviceChannel = self.channelIndex * 2
            
            var map: [NSNumber] = []
            // L
            if startDeviceChannel < inChannels {
                map.append(NSNumber(value: startDeviceChannel))
            } else {
                map.append(NSNumber(value: 0)) // フォールバック
            }
            // R
            if startDeviceChannel + 1 < inChannels {
                map.append(NSNumber(value: startDeviceChannel + 1))
            } else if inChannels > 1 {
                map.append(NSNumber(value: 1))
            } else {
                map.append(NSNumber(value: 0)) // モノラルの場合はLと同じ
            }
            conv.channelMap = map
            
            self.converter = conv
            self.inputBuffer = AVAudioPCMBuffer(pcmFormat: validDevFormat, frameCapacity: bufferCapacity)
            self.outputBuffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: bufferCapacity)
            logger.info("Ch \(self.channelIndex): Setup Converter [\(validDevFormat.sampleRate)Hz -> \(self.engineFormat.sampleRate)Hz] map: \(map)")
        } else {
            logger.error("Ch \(self.channelIndex): Failed to create AVAudioConverter")
        }
    }
    
    // MARK: - IO Proc Control
    
    func start() -> Bool {
        guard !isRunning, deviceID != 0, converter != nil, inputBuffer != nil, outputBuffer != nil else { return false }
        
        let success = SharedDeviceIOProcManager.shared.startCapturing(deviceID: deviceID, capturer: self)
        if success {
            isRunning = true
            logger.info("Ch \(self.channelIndex): Started capturing device \(self.deviceID)")
        } else {
            logger.error("Ch \(self.channelIndex): Failed to start capturing device \(self.deviceID)")
        }
        return success
    }
    
    func stop() {
        guard isRunning else { return }
        
        SharedDeviceIOProcManager.shared.stopCapturing(deviceID: deviceID, capturer: self)
        self.isRunning = false
        
        for i in 0..<totalBuffers {
            TPCircularBufferClear(&ringBuffersPointer[i])
        }
        logger.info("Ch \(self.channelIndex): Stopped capturing device \(self.deviceID)")
    }
    
    // MARK: - Buffer Processing (Real-time thread)
    
    fileprivate func processInput(bufferList: UnsafePointer<AudioBufferList>?) {
        guard let list = bufferList, let converter = converter, let inBuffer = inputBuffer, let outBuffer = outputBuffer else { return }
        
        let numBuffers = Int(list.pointee.mNumberBuffers)
        let mutableList = UnsafeMutablePointer<AudioBufferList>(mutating: list)
        let srcBuffers = UnsafeMutableAudioBufferListPointer(mutableList)
        
        // 1. 入力データを inputBuffer にコピー
        var frameLength: AVAudioFrameCount = 0
        if numBuffers > 0 {
            guard let avFmt = avDeviceFormat else { return }
            let bytesPerFrame = avFmt.streamDescription.pointee.mBytesPerFrame
            frameLength = AVAudioFrameCount(srcBuffers[0].mDataByteSize / bytesPerFrame)
            if frameLength > bufferCapacity { frameLength = bufferCapacity }
            
            inBuffer.frameLength = frameLength
            let dstBuffers = UnsafeMutableAudioBufferListPointer(inBuffer.mutableAudioBufferList)
            
            for i in 0..<min(numBuffers, dstBuffers.count) {
                if let srcData = srcBuffers[i].mData, let dstData = dstBuffers[i].mData {
                    let bytesToCopy = Int(frameLength) * Int(bytesPerFrame)
                    memcpy(dstData, srcData, bytesToCopy)
                    
                    // --- デバッグ: 入力データが本当に無音かチェック（数フレームに1回ログ） ---
                    if i == 0 {
                        frameCountForLog += 1
                        if frameCountForLog % 100 == 0 {
                            let floatPtr = srcData.bindMemory(to: Float.self, capacity: Int(frameLength))
                            var peak: Float = 0.0
                            for f in 0..<Int(frameLength) {
                                peak = max(peak, abs(floatPtr[f]))
                            }
                            logger.debug("Ch \(self.channelIndex): Input Peak = \(peak)")
                        }
                    }
                }
            }
        }

        
        guard frameLength > 0 else { return }
        
        // 2. AVAudioConverter で Float32 ステレオ (engineFormat) に変換
        outBuffer.frameLength = bufferCapacity
        var error: NSError?
        var hasProvidedInput = false
        
        let status = converter.convert(to: outBuffer, error: &error) { inNumPackets, outStatus in
            if hasProvidedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            hasProvidedInput = true
            return inBuffer
        }
        
        if status == .error {
            // エラー時のみログを出す（毎フレーム出ると多すぎるため、一定頻度で出すなどの工夫が必要だが今回は直接出力）
            logger.error("Ch \(self.channelIndex): Converter error: \(String(describing: error))")
            return
        }
        if outBuffer.frameLength == 0 {
            // 無音（変換後0フレーム）の場合は無視
            logger.debug("Ch \(self.channelIndex): Converter output 0 frames (silence)")
            return
        }
        
        // 3. 変換後のデータをリングバッファに書き込み
        guard let channelData = outBuffer.floatChannelData else { return }
        let channelCount = Int(outBuffer.format.channelCount)
        let framesToStore = outBuffer.frameLength
        let bytesToWrite = Int32(framesToStore) * Int32(MemoryLayout<Float>.size)
        
        for i in 0..<channelCount {
            guard i < channelsPerBus else { break }
            let dataPointer = channelData[i]
            let currentGain = gain
            let frameCount = Int(framesToStore)
            
            // ゲインを各サンプルに適用
            if currentGain != 1.0 {
                for f in 0..<frameCount {
                    dataPointer[f] *= currentGain
                }
            }
            
            // 4つの出力バスすべてにデータを書き込む
            for bus in 0..<numOutputBuses {
                let bufferIndex = bus * channelsPerBus + i
                
                let framesStored = ringBuffersPointer[bufferIndex].fillCount / Int32(MemoryLayout<Float>.size)
                
                // レイテンシ制御: 古いデータを破棄してサイズを調整
                if framesStored > maxFramesToKeep {
                    let excessBytes = (framesStored - maxFramesToKeep) * Int32(MemoryLayout<Float>.size)
                    TPCircularBufferConsume(&ringBuffersPointer[bufferIndex], excessBytes)
                }
                
                TPCircularBufferProduce(&ringBuffersPointer[bufferIndex], dataPointer, bytesToWrite)
                
                // モノラルアップミックス
                if channelCount == 1 && channelsPerBus > 1 {
                    let rightBufferIndex = bus * channelsPerBus + 1
                    let rightFramesStored = ringBuffersPointer[rightBufferIndex].fillCount / Int32(MemoryLayout<Float>.size)
                    if rightFramesStored > maxFramesToKeep {
                        let excessBytes = (rightFramesStored - maxFramesToKeep) * Int32(MemoryLayout<Float>.size)
                        TPCircularBufferConsume(&ringBuffersPointer[rightBufferIndex], excessBytes)
                    }
                    TPCircularBufferProduce(&ringBuffersPointer[rightBufferIndex], dataPointer, bytesToWrite)
                }
            }
        }
    }
    
    // MARK: - Render Block (AVAudioSourceNode callback)
    
    /// AVAudioSourceNode から呼び出される Render Block を提供 (指定された出力バス用)
    func createRenderBlock(forOutputBus busIndex: Int) -> AVAudioSourceNodeRenderBlock {
        return { [weak self] (isSilence, timestamp, frameCount, outputData) -> OSStatus in
            guard let self = self, busIndex < self.numOutputBuses else { return noErr }
            
            // Non-interleaved Float32 なので 1チャンネル分のバイト数 = frameCount × 4bytes
            let byteCount = Int32(frameCount) * Int32(MemoryLayout<Float>.size)
            
            let outBuffers = UnsafeMutableAudioBufferListPointer(outputData)
            
            for (i, outBuffer) in outBuffers.enumerated() {
                guard let outData = outBuffer.mData else { continue }
                
                // 該当する出力バスの、対応するL/Rバッファからデータを読み出す
                let channelOffset = i < self.channelsPerBus ? i : 0
                let ringBufferIndex = busIndex * self.channelsPerBus + channelOffset
                
                let consumed = TPCircularBufferConsumeToBuffer(&self.ringBuffersPointer[ringBufferIndex], outData, byteCount)
                
                if !consumed {
                    // バッファアンダーラン: データが足りない場合は無音を出力
                    memset(outData, 0, Int(byteCount))
                    
                    // デバッグ用に時々ログを出す
                    if ringBufferIndex == 0 {
                        self.frameCountForLog += 1
                        if self.frameCountForLog % 100 == 0 {
                            let available = self.ringBuffersPointer[ringBufferIndex].fillCount
                            self.logger.debug("Ch \(self.channelIndex): Underrun! Requested \(byteCount) bytes, available \(available)")
                        }
                    }
                }
            }
            
            return noErr
        }
    }
}

// MARK: - Shared IOProc Manager

/// 同じAudioDeviceIDに対する複数のキャプチャを1つのIOProcで共有・分配するためのマネージャー
/// BlackHoleや一部のオーディオインターフェースにおいて、同一プロセスから複数のIOProcを作成すると音が鳴らない（無音になる）バグを回避する。
class SharedDeviceIOProcManager {
    static let shared = SharedDeviceIOProcManager()
    
    private let logger = AppLogger(category: "SharedDeviceIOProc")
    private let lock = NSLock()
    
    private var capturers: [AudioDeviceID: [AudioInputCapturer]] = [:]
    private var ioProcs: [AudioDeviceID: AudioDeviceIOProcID] = [:]
    
    func startCapturing(deviceID: AudioDeviceID, capturer: AudioInputCapturer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        var list = capturers[deviceID] ?? []
        list.append(capturer)
        capturers[deviceID] = list
        
        // 既にIOProcが起動している場合はリストに追加するだけで成功
        if ioProcs[deviceID] != nil {
            return true
        }
        
        // 新規にIOProcを作成して起動する
        let ioProc: AudioDeviceIOProc = { (deviceID, inNow, inInputData, inInputTime, outOutputData, inOutputTime, clientData) -> OSStatus in
            // このブロックはリアルタイムスレッドで呼ばれるため、ロックは避けるべきだが、
            // 今回は単純化のためにSharedDeviceIOProcManager経由で分配する
            let manager = Unmanaged<SharedDeviceIOProcManager>.fromOpaque(clientData!).takeUnretainedValue()
            manager.distributeInput(deviceID: deviceID, bufferList: inInputData)
            return noErr
        }
        
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(deviceID, ioProc, selfPointer, &procID)
        
        guard status == noErr, let validProcID = procID else {
            logger.error("Failed to create shared IOProc for device \(deviceID): \(status)")
            return false
        }
        
        status = AudioDeviceStart(deviceID, validProcID)
        guard status == noErr else {
            logger.error("Failed to start shared AudioDevice \(deviceID): \(status)")
            AudioDeviceDestroyIOProcID(deviceID, validProcID)
            return false
        }
        
        ioProcs[deviceID] = validProcID
        logger.info("Created and started shared IOProc for device \(deviceID)")
        return true
    }
    
    func stopCapturing(deviceID: AudioDeviceID, capturer: AudioInputCapturer) {
        lock.lock()
        defer { lock.unlock() }
        
        guard var list = capturers[deviceID] else { return }
        list.removeAll(where: { $0 === capturer })
        
        if list.isEmpty {
            capturers.removeValue(forKey: deviceID)
            if let procID = ioProcs.removeValue(forKey: deviceID) {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
                logger.info("Stopped and destroyed shared IOProc for device \(deviceID)")
            }
        } else {
            capturers[deviceID] = list
        }
    }
    
    // リアルタイムスレッドから呼ばれる
    private func distributeInput(deviceID: AudioDeviceID, bufferList: UnsafePointer<AudioBufferList>?) {
        // ※厳密にはここでロックを取るのはPriority Inversionの危険があるが、
        // macOSのCoreAudio HALコールバック内での単純なロック取得は通常問題になりにくい
        lock.lock()
        let activeCapturers = capturers[deviceID]
        lock.unlock()
        
        guard let list = activeCapturers else { return }
        for capturer in list {
            capturer.processInput(bufferList: bufferList)
        }
    }
}
