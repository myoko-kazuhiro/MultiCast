import Foundation
import AVFoundation
import Accelerate

/// リアルタイム音量レベルの計算を行う
class LevelMeter {
    /// ピーク減衰レート（1秒あたり）
    private let peakDecayRate: Float = 20.0
    
    /// レベルの平滑化係数
    private let smoothingFactor: Float = 0.3
    
    /// 最小レベル (dBFS)
    static let minimumLevel: Float = -60.0
    
    /// 最大レベル (dBFS)
    static let maximumLevel: Float = 0.0
    
    /// オーディオバッファからL/Rレベルを計算
    func calculateLevels(buffer: AVAudioPCMBuffer) -> (left: Float, right: Float) {
        guard let floatData = buffer.floatChannelData else {
            return (LevelMeter.minimumLevel, LevelMeter.minimumLevel)
        }
        
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        
        guard frameLength > 0 else {
            return (LevelMeter.minimumLevel, LevelMeter.minimumLevel)
        }
        
        let leftRMS = calculateRMS(data: floatData[0], count: frameLength)
        let leftDB = linearToDecibels(leftRMS)
        
        var rightDB = leftDB
        if channelCount >= 2 {
            let rightRMS = calculateRMS(data: floatData[1], count: frameLength)
            rightDB = linearToDecibels(rightRMS)
        }
        
        return (
            left: max(LevelMeter.minimumLevel, leftDB),
            right: max(LevelMeter.minimumLevel, rightDB)
        )
    }
    
    /// RMSレベルを計算（vDSP使用で高速化）
    private func calculateRMS(data: UnsafePointer<Float>, count: Int) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(count))
        return rms
    }
    
    /// リニア値をdBFSに変換
    private func linearToDecibels(_ value: Float) -> Float {
        guard value > 0 else { return LevelMeter.minimumLevel }
        return 20.0 * log10(value)
    }
    
    /// dBFS値をリニア値（0.0-1.0）に正規化
    static func normalizeLevel(_ dbLevel: Float) -> Float {
        if dbLevel <= minimumLevel { return 0.0 }
        if dbLevel >= maximumLevel { return 1.0 }
        return (dbLevel - minimumLevel) / (maximumLevel - minimumLevel)
    }
    
    /// ピークホールドの減衰を計算
    static func decayPeak(currentPeak: Float, deltaTime: Float, decayRate: Float = 20.0) -> Float {
        let decayed = currentPeak - (decayRate * deltaTime)
        return max(minimumLevel, decayed)
    }
}
