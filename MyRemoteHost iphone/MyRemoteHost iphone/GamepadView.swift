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
                
                // ★ Phase 2: 全知全能HUD (Omniscient HUD)
                if viewModel.showHUD, let state = viewModel.currentOmniscientState {
                    VStack {
                        OmniscientHUD(state: state)
                            .padding(.top, 60) // ステータスバーの下
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100) // 最前面
                    .allowsHitTesting(false) // 操作を邪魔しない
                }
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }
    
    // MARK: - Full Screen Preview (ROI-Only Zoom)
    
    /// 仮想ズーム倍率（表示は1:1のまま、macOS側のキャプチャ領域のみ変更）
    @State private var virtualZoom: CGFloat = 1.0
    @State private var lastPinchScale: CGFloat = 1.0
    
    /// 仮想パン位置（正規化座標 0〜1）
    @State private var virtualOffset: CGSize = .zero
    @State private var lastDragOffset: CGSize = .zero
    
    private func fullScreenPreview(geometry: GeometryProxy) -> some View {
        // 常に1:1でプレビュー表示（ローカルズームなし）
        CoordinatedPreviewView(coordinator: viewModel.previewCoordinator)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            // ピンチ → 仮想ズーム（macOS ROI制御のみ）
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let newScale = max(1.0, min(5.0, lastPinchScale * value))
                        virtualZoom = newScale
                        sendROIRequest()
                    }
                    .onEnded { value in
                        lastPinchScale = virtualZoom
                        if virtualZoom < 1.1 {
                            // ほぼ等倍 → リセット
                            virtualZoom = 1.0
                            lastPinchScale = 1.0
                            virtualOffset = .zero
                            lastDragOffset = .zero
                            sendROIRequest()
                        }
                    }
            )
            // ドラッグ → 仮想パン（ズーム中のみ）
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard virtualZoom > 1.1 else { return }
                        let sensitivity: CGFloat = 1.0 / (geometry.size.width * virtualZoom)
                        let dx = lastDragOffset.width - value.translation.width * sensitivity
                        let dy = lastDragOffset.height - value.translation.height * sensitivity
                        virtualOffset = CGSize(
                            width: max(0, min(1.0 - 1.0 / virtualZoom, dx)),
                            height: max(0, min(1.0 - 1.0 / virtualZoom, dy))
                        )
                        sendROIRequest()
                    }
                    .onEnded { _ in
                        lastDragOffset = virtualOffset
                    }
            )
            .onTapGesture(count: 3) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
            }
            // ダブルタップ → ズームイン/リセット
            .onTapGesture(count: 2) {
                if virtualZoom > 1.1 {
                    // リセット
                    virtualZoom = 1.0
                    lastPinchScale = 1.0
                    virtualOffset = .zero
                    lastDragOffset = .zero
                } else {
                    // 2.5倍ズーム（中央）
                    virtualZoom = 2.5
                    lastPinchScale = 2.5
                    virtualOffset = CGSize(width: 0.3, height: 0.3)
                    lastDragOffset = virtualOffset
                }
                sendROIRequest()
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
                    
                    // ★ ROIズーム倍率（1.5x以上で表示）
                    if virtualZoom > 1.4 {
                        Text("ROI \(String(format: "%.1f", virtualZoom))x")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.cyan)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.6))
                .cornerRadius(8)
                

                
                // ★ Phase 2: HUD切替ボタン
                Button(action: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        viewModel.showHUD.toggle()
                    }
                }) {
                    Image(systemName: viewModel.showHUD ? "chart.bar.doc.horizontal.fill" : "chart.bar.doc.horizontal")
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                }
                
                // ★ 切断ボタン (長押しで誤操作防止)
                if viewModel.isConnected {
                    Button(action: {
                        // タップでは何もしない（長押し誘導のトーストを出しても良いが今回は省略）
                    }) {
                        Image(systemName: "power")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.red.opacity(0.8))
                            .clipShape(Circle())
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 1.0)
                            .onEnded { _ in
                                let generator = UINotificationFeedbackGenerator()
                                generator.notificationOccurred(.warning)
                                viewModel.disconnect()
                            }
                    )
                    .overlay(
                        // 長押しヒント
                        Text("Hold")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .offset(y: 20)
                            .opacity(0.8)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            
            // HUD Overlay
            if viewModel.showHUD, let state = viewModel.currentOmniscientState {
                OmniscientHUD(state: state)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 4)
                    .zIndex(1)
            }
            
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
    // MARK: - ROI Request
    
    /// 仮想ズーム＆パン状態からvisibleRectを計算してmacOSに送信
    private func sendROIRequest() {
        let w = 1.0 / virtualZoom
        let h = 1.0 / virtualZoom
        let x = virtualOffset.width
        let y = virtualOffset.height
        let visibleRect = CGRect(x: x, y: y, width: w, height: h)
        
        viewModel.updateZoomState(scale: virtualZoom, visibleRect: visibleRect)
    }
}

#Preview {
    GamepadView(viewModel: RemoteViewModel())
}
