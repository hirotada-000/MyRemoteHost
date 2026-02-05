//
//  VirtualJoystick.swift
//  MyRemoteHost iphone
//
//  バーチャルジョイスティック - マウスカーソル移動用
//

import SwiftUI

/// バーチャルジョイスティックコンポーネント
struct VirtualJoystick: View {
    
    /// ジョイスティックの移動コールバック (dx, dy) -1.0〜1.0
    var onMove: (Float, Float) -> Void
    
    /// リリース時のコールバック
    var onRelease: () -> Void
    
    // MARK: - State
    
    @State private var knobOffset: CGSize = .zero
    @State private var isDragging = false
    
    // MARK: - Configuration
    
    private let baseSize: CGFloat = 120
    private let knobSize: CGFloat = 50
    private let maxOffset: CGFloat = 35
    private let deadZone: CGFloat = 5
    
    var body: some View {
        ZStack {
            // ベース（外側の円）
            Circle()
                .fill(Color.white.opacity(0.1))
                .frame(width: baseSize, height: baseSize)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 2)
                )
            
            // 方向インジケーター
            ForEach(0..<4) { index in
                let angle = Double(index) * 90
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.3))
                    .rotationEffect(.degrees(angle))
                    .offset(
                        x: cos(CGFloat(angle - 90) * .pi / 180) * (baseSize / 2 - 15),
                        y: sin(CGFloat(angle - 90) * .pi / 180) * (baseSize / 2 - 15)
                    )
            }
            
            // ノブ（内側の円）
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isDragging ? 0.8 : 0.5),
                            Color.white.opacity(isDragging ? 0.6 : 0.3)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: knobSize, height: knobSize)
                .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 2)
                .offset(knobOffset)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    
                    // オフセットを計算（最大値で制限）
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let distance = sqrt(dx * dx + dy * dy)
                    
                    if distance > maxOffset {
                        // 最大距離で正規化
                        let scale = maxOffset / distance
                        knobOffset = CGSize(width: dx * scale, height: dy * scale)
                    } else {
                        knobOffset = value.translation
                    }
                    
                    // コールバック（デッドゾーン考慮）
                    if distance > deadZone {
                        let normalizedX = Float(knobOffset.width / maxOffset)
                        let normalizedY = Float(knobOffset.height / maxOffset)
                        onMove(normalizedX, normalizedY)
                    }
                }
                .onEnded { _ in
                    isDragging = false
                    // アニメーションなしで即座にリセット
                    knobOffset = .zero
                    onRelease()
                }
        )
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VirtualJoystick(
            onMove: { dx, dy in
                // print("Move: \(dx), \(dy)")
            },
            onRelease: {
                // print("Released")
            }
        )
    }
}
