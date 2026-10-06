import SwiftUI
import AVFoundation

/// MultiCast アプリケーションのエントリポイント
@main
struct MultiCastApp: App {
    private let logger = AppLogger(category: "App")
    @Environment(\.openWindow) private var openWindow
    
    /// コアオブジェクト
    @StateObject private var audioRoute = AudioRoute()
    @StateObject private var deviceManager = AudioDeviceManager.shared
    
    /// エンジンと管理オブジェクト（audioRouteに依存するため遅延初期化）
    @State private var mixerEngine: AudioMixerEngine?
    @State private var lifecycleManager: AudioLifecycleManager?
    @State private var deviceMonitor: AudioDeviceMonitor?
    @State private var healthMonitor: AudioHealthMonitor?
    
    var body: some Scene {
        // メインウィンドウ
        WindowGroup {
            Group {
                if let engine = mixerEngine {
                    ContentView(
                        audioRoute: audioRoute,
                        mixerEngine: engine,
                        deviceManager: deviceManager
                    )
                } else {
                    ProgressView("初期化中...")
                        .frame(width: 300, height: 200)
                        .preferredColorScheme(.dark)
                }
            }
            .onAppear {
                LogStore.shared.registerCrashHandlers()
                initializeAudioSystem()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 640, height: 600)
        
        Window("エラーログ", id: "LogViewer") {
            LogViewerView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 850, height: 500)
        
        // メニューバー
        MenuBarExtra {
            if let engine = mixerEngine {
                MenuBarView(
                    mixerEngine: engine,
                    audioRoute: audioRoute,
                    onOpenLogs: { openWindow(id: "LogViewer") },
                    onShowMainWindow: {
                        NSApp.activate(ignoringOtherApps: true)
                        if let window = NSApp.windows.first {
                            window.makeKeyAndOrderFront(nil)
                        }
                    },
                    onQuit: {
                        shutdown()
                        NSApp.terminate(nil)
                    }
                )
            } else {
                Text("初期化中...")
            }
        } label: {
            Image(systemName: "waveform.circle.fill")
        }
    }
    
    // MARK: - Initialization
    
    private func initializeAudioSystem() {
        guard mixerEngine == nil else { return }
        
        logger.info("Initializing audio system...")
        
        // マイクアクセス権限を要求する
        // (CoreAudio HAL を直接使用する場合、自動でプロンプトが出ないためここで明示的に要求が必要)
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if granted {
                    self.logger.info("Microphone access granted")
                } else {
                    self.logger.error("Microphone access denied! Audio input will be silent.")
                }
                self.continueInitialization()
            }
        }
    }
    
    private func continueInitialization() {
        // 1. 設定を復元
        audioRoute.loadFromDisk()
        
        // 2. エンジンを作成
        let engine = AudioMixerEngine(audioRoute: audioRoute)
        self.mixerEngine = engine
        
        // 3. デバイスの照合・復元
        restoreDeviceAssignments()
        
        // 4. ライフサイクルマネージャー（Layer 1 & 2）
        let lifecycle = AudioLifecycleManager(
            mixerEngine: engine,
            deviceManager: deviceManager,
            audioRoute: audioRoute
        )
        self.lifecycleManager = lifecycle
        
        // 5. デバイスモニター（Layer 3）
        let monitor = AudioDeviceMonitor(
            deviceManager: deviceManager,
            mixerEngine: engine,
            audioRoute: audioRoute
        )
        self.deviceMonitor = monitor
        
        // 6. ヘルスモニター（Layer 4）
        let health = AudioHealthMonitor(
            mixerEngine: engine,
            deviceManager: deviceManager,
            audioRoute: audioRoute
        )
        health.onRecoveryNeeded = { [weak lifecycle] reason in
            logger.warning("Health monitor triggered recovery: \(reason.description)")
            lifecycle?.manualRecovery()
        }
        health.startMonitoring()
        self.healthMonitor = health
        
        // 7. エンジンを起動
        engine.start()
        
        logger.info("Audio system initialized successfully")
    }
    
    /// 保存された設定からデバイスを照合して割り当て
    private func restoreDeviceAssignments() {
        for channel in audioRoute.inputChannels {
            guard !channel.selectedDeviceUID.isEmpty else { continue }
            
            let result = deviceManager.resolveDevice(
                uid: channel.selectedDeviceUID,
                name: channel.selectedDevice.name,
                type: .input
            )
            
            if let device = result.device {
                channel.selectedDevice = device
                channel.selectedDeviceUID = device.uid
            } else {
                channel.selectedDevice = .none
                channel.selectedDeviceUID = ""
            }
        }
        
        for bus in audioRoute.outputBuses {
            guard !bus.selectedDeviceUID.isEmpty else { continue }
            
            let result = deviceManager.resolveDevice(
                uid: bus.selectedDeviceUID,
                name: bus.selectedDevice.name,
                type: .output
            )
            
            if let device = result.device {
                bus.selectedDevice = device
                bus.selectedDeviceUID = device.uid
            } else {
                bus.selectedDevice = .none
                bus.selectedDeviceUID = ""
            }
        }
    }
    
    // MARK: - Shutdown
    
    private func shutdown() {
        logger.info("Shutting down...")
        
        // 設定を保存
        audioRoute.saveToDisk()
        
        // ヘルスモニター停止
        healthMonitor?.stopMonitoring()
        
        // デバイスモニターのリスナー解除
        deviceMonitor?.removeListeners()
        
        // エンジン停止
        mixerEngine?.stop()
        
        logger.info("Shutdown complete")
    }
}
