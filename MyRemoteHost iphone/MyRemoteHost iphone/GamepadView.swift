//
//  GamepadView.swift
//  MyRemoteHost iphone
//
//  ★ リモート操作ビュー
//  設計思想: プレビューを最大化し、コントローラーは半透明オーバーレイ
//

import SwiftUI

/// リモート操作ビュー（フルスクリーンプレビュー + オーバーレイコントローラー）
struct GamepadView: View {
    
    @ObservedObject var viewModel: RemoteViewModel
    
    /// 現在のマウス位置（正規化 0.0-1.0）
    @State private var mouseX: Float = 0.5
    @State private var mouseY: Float = 0.5
    
    /// コントローラー表示状態（タップで切り替え）
    @State private var showControls = true
    
    /// マウス移動速度（感度）
    private let mouseSensitivity: Float = 0.02
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // ★ 背景: 画面全体をプレビューが覆う
                fullScreenPreview(geometry: geometry)
                
                // ★ オーバーレイ: コントローラー（半透明）
                if showControls {
                    controlsOverlay(geometry: geometry)
                }
                
                // ★ ステータスバー（常時表示）
                statusBar
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }
    
    // MARK: - Full Screen Preview
    
    private func fullScreenPreview(geometry: GeometryProxy) -> some View {
        ZoomableScrollView(
            minZoom: 1.0,
            maxZoom: 5.0,
            onZoomChanged: { scale, visibleRect in
                viewModel.updateZoomState(scale: scale, visibleRect: visibleRect)
            }
        ) {
            CoordinatedPreviewView(coordinator: viewModel.previewCoordinator)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onTapGesture(count: 3) {
            // 3回タップでコントローラー表示切り替え
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
        }
    }
    
    // MARK: - Controls Overlay
    
    private func controlsOverlay(geometry: GeometryProxy) -> some View {
        HStack {
            // 左側: ジョイスティック
            VStack {
                Spacer()
                VirtualJoystick(
                    onMove: { dx, dy in
                        mouseX = max(0, min(1, mouseX + dx * mouseSensitivity))
                        mouseY = max(0, min(1, mouseY + dy * mouseSensitivity))
                        viewModel.inputSender.sendMouseMove(
                            normalizedX: mouseX,
                            normalizedY: mouseY
                        )
                    },
                    onRelease: {}
                )
                .opacity(0.7)  // ★ 半透明
                Spacer()
            }
            .frame(width: geometry.size.width * 0.25)
            .padding(.leading, 10)
            
            Spacer()
            
            // 右側: アクションボタン
            VStack {
                Spacer()
                ActionButtons(
                    onLeftClick: {
                        viewModel.inputSender.sendMouseDown(button: .left)
                        viewModel.inputSender.sendMouseUp(button: .left)
                    },
                    onRightClick: {
                        viewModel.inputSender.sendMouseDown(button: .right)
                        viewModel.inputSender.sendMouseUp(button: .right)
                    },
                    onScroll: { deltaY in
                        viewModel.inputSender.sendScroll(deltaX: 0, deltaY: deltaY)
                    }
                )
                .opacity(0.7)  // ★ 半透明
                Spacer()
            }
            .frame(width: geometry.size.width * 0.15)
            .padding(.trailing, 10)
        }
    }
    
    // MARK: - Status Bar
    
    private var statusBar: some View {
        VStack {
            HStack {
                // ★ モードバッジ（常に表示・超目立つ）
                modeIndicator
                
                Spacer()
                
                // FPS + ズーム（右上）
                HStack(spacing: 8) {
                    // FPS表示
                    Text("\(String(format: "%.0f", viewModel.frameRate)) FPS")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.9))
                    
                    // ★ ズーム倍率（1.5x以上で表示）
                    if viewModel.zoomScale > 1.4 {
                        Text("\(String(format: "%.1f", viewModel.zoomScale))x")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.cyan)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.6))
                .cornerRadius(8)
                
                // ★ 切断ボタン
                Button(action: {
                    viewModel.disconnect()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                        Text("切断")
                            .font(.caption2)
                    }
                    .foregroundColor(.red.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            
            Spacer()
        }
    }
    
    // MARK: - Mode Indicator
    
    /// ★ 超目立つモードインジケーター
    private var modeIndicator: some View {
        Group {
            if viewModel.currentPNGData != nil {
                // PNG モード - 緑色で超目立つ
                HStack(spacing: 6) {
                    Image(systemName: "photo.fill")
                        .font(.title3)
                    Text("PNG")
                        .font(.headline)
                        .fontWeight(.black)
                    Text("高画質")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.green, Color.green.opacity(0.7)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(12)
                .shadow(color: .green.opacity(0.5), radius: 8, x: 0, y: 2)
            } else {
                // VIDEO モード - 青色で表示
                HStack(spacing: 6) {
                    Image(systemName: "video.fill")
                        .font(.title3)
                    Text("VIDEO")
                        .font(.headline)
                        .fontWeight(.black)
                    Text("ストリーム")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.blue, Color.blue.opacity(0.7)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(12)
                .shadow(color: .blue.opacity(0.5), radius: 8, x: 0, y: 2)
            }
        }
    }
}

#Preview {
    GamepadView(viewModel: RemoteViewModel())
}
