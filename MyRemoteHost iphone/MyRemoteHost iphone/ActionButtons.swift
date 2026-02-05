//
//  ActionButtons.swift
//  MyRemoteHost iphone
//
//  アクションボタン - クリック、右クリック、スクロール用
//

import SwiftUI

/// アクションボタンコンポーネント
struct ActionButtons: View {
    
    /// 左クリック
    var onLeftClick: () -> Void
    
    /// 右クリック
    var onRightClick: () -> Void
    
    /// スクロール (deltaY: 正=下, 負=上)
    var onScroll: (Float) -> Void
    
    // MARK: - State
    
    @State private var isAPressed = false
    @State private var isBPressed = false
    @State private var scrollOffset: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 15) {
            // Aボタン（左クリック）
            ActionButton(
                label: "A",
                color: .blue,
                isPressed: $isAPressed,
                onTap: onLeftClick
            )
            
            // Bボタン（右クリック）
            ActionButton(
                label: "B",
                color: .red,
                isPressed: $isBPressed,
                onTap: onRightClick
            )
            
            // スクロールボタン
            ScrollButton(onScroll: onScroll)
        }
    }
}

/// 単一のアクションボタン
struct ActionButton: View {
    let label: String
    let color: Color
    @Binding var isPressed: Bool
    var onTap: () -> Void
    
    private let size: CGFloat = 55
    
    var body: some View {
        ZStack {
            // 影（押されてないとき）
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: size, height: size)
                .offset(y: isPressed ? 0 : 3)
            
            // ボタン本体
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            color.opacity(isPressed ? 0.6 : 0.9),
                            color.opacity(isPressed ? 0.4 : 0.7)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 2)
                )
                .scaleEffect(isPressed ? 0.95 : 1.0)
            
            // ラベル
            Text(label)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                        impactFeedback.impactOccurred()
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    onTap()
                }
        )
    }
}

/// スクロールボタン（上下ドラッグ対応）
struct ScrollButton: View {
    var onScroll: (Float) -> Void
    
    @State private var isDragging = false
    @State private var lastY: CGFloat = 0
    
    private let size: CGFloat = 55
    
    var body: some View {
        ZStack {
            // ボタン本体
            RoundedRectangle(cornerRadius: 15)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.gray.opacity(isDragging ? 0.6 : 0.5),
                            Color.gray.opacity(isDragging ? 0.4 : 0.3)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size, height: 70)
                .overlay(
                    RoundedRectangle(cornerRadius: 15)
                        .stroke(Color.white.opacity(0.3), lineWidth: 2)
                )
            
            // アイコン
            VStack(spacing: 2) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(.white.opacity(0.8))
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        lastY = value.location.y
                    }
                    
                    let deltaY = value.location.y - lastY
                    if abs(deltaY) > 5 {
                        onScroll(Float(deltaY) * 0.1)
                        lastY = value.location.y
                    }
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        ActionButtons(
            onLeftClick: { /* print("Left click") */ },
            onRightClick: { /* print("Right click") */ },
            onScroll: { delta in /* print("Scroll: \(delta)") */ }
        )
    }
}
