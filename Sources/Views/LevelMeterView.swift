import SwiftUI

/// レベルメーターの表示コンポーネント
struct LevelMeterView: View {
    /// 現在のレベル (dBFS: -60 〜 0)
    let level: Float
    
    /// ピークホールド (dBFS)
    let peak: Float
    
    /// メーターの向き
    var orientation: Orientation = .vertical
    
    /// メーターの幅（横向き時は高さ）
    var thickness: CGFloat = 6
    
    enum Orientation {
        case vertical
        case horizontal
    }
    
    /// レベルを 0.0-1.0 に正規化
    private var normalizedLevel: CGFloat {
        CGFloat(LevelMeter.normalizeLevel(level))
    }
    
    /// ピークを 0.0-1.0 に正規化
    private var normalizedPeak: CGFloat {
        CGFloat(LevelMeter.normalizeLevel(peak))
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: orientation == .vertical ? .bottom : .leading) {
                // 背景
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.4))
                
                // レベルバー（グラデーション）
                RoundedRectangle(cornerRadius: 2)
                    .fill(levelGradient)
                    .frame(
                        width: orientation == .vertical ? nil : geometry.size.width * normalizedLevel,
                        height: orientation == .vertical ? geometry.size.height * normalizedLevel : nil
                    )
                    .animation(.linear(duration: 0.05), value: normalizedLevel)
                
                // ピークホールドインジケーター
                if normalizedPeak > 0.01 {
                    Rectangle()
                        .fill(peakColor)
                        .frame(
                            width: orientation == .vertical ? nil : 2,
                            height: orientation == .vertical ? 2 : nil
                        )
                        .offset(
                            x: orientation == .horizontal ? geometry.size.width * normalizedPeak - 1 : 0,
                            y: orientation == .vertical ? -geometry.size.height * normalizedPeak + 1 : 0
                        )
                }
            }
        }
        .frame(
            width: orientation == .vertical ? thickness : nil,
            height: orientation == .horizontal ? thickness : nil
        )
    }
    
    /// レベルに応じたグラデーション（緑 → 黄 → 赤）
    private var levelGradient: LinearGradient {
        let startPoint: UnitPoint = orientation == .vertical ? .bottom : .leading
        let endPoint: UnitPoint = orientation == .vertical ? .top : .trailing
        
        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color(hue: 0.35, saturation: 0.85, brightness: 0.75), location: 0.0),
                .init(color: Color(hue: 0.25, saturation: 0.85, brightness: 0.80), location: 0.5),
                .init(color: Color(hue: 0.12, saturation: 0.90, brightness: 0.85), location: 0.75),
                .init(color: Color(hue: 0.0, saturation: 0.90, brightness: 0.85), location: 0.95),
                .init(color: Color(hue: 0.0, saturation: 1.0, brightness: 1.0), location: 1.0)
            ]),
            startPoint: startPoint,
            endPoint: endPoint
        )
    }
    
    /// ピークの色（-3dB以上なら赤）
    private var peakColor: Color {
        peak > -3.0 ? Color.red : Color.yellow
    }
}

/// ステレオレベルメーター（L/R の2本セット）
struct StereoLevelMeterView: View {
    let levelL: Float
    let levelR: Float
    let peakL: Float
    let peakR: Float
    var orientation: LevelMeterView.Orientation = .vertical
    var thickness: CGFloat = 5
    
    var body: some View {
        HStack(spacing: 1) {
            LevelMeterView(level: levelL, peak: peakL, orientation: orientation, thickness: thickness)
            LevelMeterView(level: levelR, peak: peakR, orientation: orientation, thickness: thickness)
        }
    }
}

#Preview {
    HStack(spacing: 20) {
        StereoLevelMeterView(levelL: -12, levelR: -18, peakL: -6, peakR: -10)
            .frame(height: 150)
        StereoLevelMeterView(levelL: -3, levelR: -1, peakL: 0, peakR: -1)
            .frame(height: 150)
        StereoLevelMeterView(levelL: -40, levelR: -45, peakL: -30, peakR: -35)
            .frame(height: 150)
    }
    .padding()
    .background(Color(white: 0.15))
}
