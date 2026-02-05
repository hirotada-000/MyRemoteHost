//
//  ContentView.swift
//  MyRemoteHost
//
//  メイン画面：キャプチャ制御UI
//

import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @StateObject private var viewModel = CaptureViewModel()
    @StateObject private var loginItemManager = LoginItemManager()  // ★ Phase 4
    @State private var showQRCode = false
    
    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー：コントロールパネル
            controlPanel
                .padding()
                .background(Color(.windowBackgroundColor))
            
            Divider()
            
            // メイン：プレビューエリア
            previewArea
        }
        .frame(minWidth: 900, minHeight: 650)
        .task {
            await viewModel.fetchDisplays()
        }
        .sheet(isPresented: $showQRCode) {
            qrCodeSheet
        }
        .sheet(item: $viewModel.pendingAuthClient) { client in
            authenticationSheet(client: client)
        }
    }
    
    // MARK: - Authentication Sheet
    
    private func authenticationSheet(client: PendingClient) -> some View {
        VStack(spacing: 20) {
            // ヘッダー
            HStack {
                Image(systemName: "iphone")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading) {
                    Text("接続リクエスト")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("デバイス: \(client.host)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            Divider()
            
            if viewModel.isAuthLocked {
                // ロック状態
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.red)
                    Text("認証がロックされています")
                        .font(.headline)
                    Text("30秒後に再試行してください")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else {
                // システム認証の説明
                VStack(spacing: 12) {
                    Image(systemName: "touchid")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                    
                    Text("MacのログインパスワードまたはTouch IDで認証してください")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                
                Divider()
                
                // ボタン
                HStack(spacing: 20) {
                    Button("拒否") {
                        viewModel.denyConnection()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("認証して許可") {
                        viewModel.approveWithSystemAuth()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(30)
        .frame(width: 380)
    }
    
    // MARK: - Control Panel
    
    private var controlPanel: some View {
        VStack(spacing: 12) {
            // 上段: ディスプレイ選択とモード設定
            HStack(spacing: 20) {
                displaySelector
                
                Spacer()
                
                modeSelector
                
                Spacer()
                
                networkStatus
            }
            
            Divider()
            
            // 中段: 画質・パフォーマンス設定
            qualitySettingsPanel
            
            Divider()
            
            // 下段: 統計情報とボタン
            HStack(spacing: 20) {
                statsView
                
                Spacer()
                
                captureButtons
            }
        }
    }
    
    // MARK: - Quality Settings Panel
    
    private var qualitySettingsPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text("画質・パフォーマンス設定")
                    .font(.headline)
                
                Spacer()
                
                Button("最低") {
                    viewModel.setMinQuality()
                }
                .buttonStyle(.bordered)
                
                Button("最高") {
                    viewModel.setMaxQuality()
                }
                .buttonStyle(.borderedProminent)
            }
            
            // 基本設定
            HStack(spacing: 30) {
                // ビットレート
                VStack(alignment: .leading, spacing: 2) {
                    Text("ビットレート: \(Int(viewModel.bitRateMbps)) Mbps")
                        .font(.caption)
                    Slider(value: $viewModel.bitRateMbps, in: 1...100, step: 1)
                        .frame(width: 150)
                }
                
                // フレームレート
                VStack(alignment: .leading, spacing: 2) {
                    Text("FPS: \(Int(viewModel.targetFPS))")
                        .font(.caption)
                    Slider(value: $viewModel.targetFPS, in: 15...120, step: 5)
                        .frame(width: 120)
                }
                
                // キーフレーム間隔
                VStack(alignment: .leading, spacing: 2) {
                    Text("キーフレーム間隔: \(Int(viewModel.keyFrameInterval))")
                        .font(.caption)
                    Slider(value: $viewModel.keyFrameInterval, in: 1...60, step: 1)
                        .frame(width: 120)
                }
                
                // 解像度スケール
                VStack(alignment: .leading, spacing: 2) {
                    Text("解像度: \(Int(viewModel.resolutionScale * 100))%")
                        .font(.caption)
                    Slider(value: $viewModel.resolutionScale, in: 0.25...1.0, step: 0.05)
                        .frame(width: 120)
                }
                
                // プロファイル
                VStack(alignment: .leading, spacing: 2) {
                    Text("プロファイル")
                        .font(.caption)
                    Picker("", selection: $viewModel.profileIndex) {
                        Text("Baseline").tag(0)
                        Text("Main").tag(1)
                        Text("High").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }
            
            Divider()
            
            // ★ 詳細設定 (新規追加)
            HStack(spacing: 30) {
                // 品質 (Quality)
                VStack(alignment: .leading, spacing: 2) {
                    Text("品質: \(String(format: "%.0f", viewModel.quality * 100))%")
                        .font(.caption)
                    Slider(value: $viewModel.quality, in: 0.5...1.0, step: 0.05)
                        .frame(width: 120)
                }
                
                // コーデック選択
                VStack(alignment: .leading, spacing: 2) {
                    Text("コーデック")
                        .font(.caption)
                    Picker("", selection: $viewModel.codecIndex) {
                        Text("H.264").tag(0)
                        Text("HEVC").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                
                // 低遅延モード
                VStack(alignment: .leading, spacing: 2) {
                    Text("低遅延モード")
                        .font(.caption)
                    Toggle("", isOn: $viewModel.lowLatencyMode)
                        .toggleStyle(.switch)
                }
                
                // ピークビットレート倍率
                VStack(alignment: .leading, spacing: 2) {
                    Text("ピーク倍率: \(String(format: "%.1f", viewModel.peakBitRateMultiplier))x")
                        .font(.caption)
                    Slider(value: $viewModel.peakBitRateMultiplier, in: 1.0...3.0, step: 0.1)
                        .frame(width: 100)
                }
                
                Spacer()
                
                // ★ ハイブリッドモード
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("ハイブリッド")
                            .font(.caption)
                        Text("(\(viewModel.currentMode))")
                            .font(.caption2)
                            .foregroundColor(viewModel.currentMode == "PNG" ? .green : .blue)
                    }
                    Toggle("", isOn: $viewModel.hybridMode)
                        .toggleStyle(.switch)
                }
                
                /*
                // JPEG 品質 (削除: PNGはLosslessなので設定不要)
                if viewModel.hybridMode {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("JPEG品質: \(Int(viewModel.jpegQuality * 100))%")
                            .font(.caption)
                        Slider(value: $viewModel.jpegQuality, in: 0.7...1.0, step: 0.05)
                            .frame(width: 80)
                    }
                }
                */
            }
        }
        .padding(.vertical, 4)
    }
    
    private var displaySelector: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ディスプレイ")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if viewModel.availableDisplays.isEmpty {
                Text("取得中...")
                    .foregroundColor(.secondary)
            } else {
                Picker("", selection: $viewModel.selectedDisplayIndex) {
                    ForEach(Array(viewModel.availableDisplays.enumerated()), id: \.offset) { index, display in
                        Text("ディスプレイ \(index + 1) (\(display.width)x\(display.height))")
                            .tag(index)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)
                .disabled(viewModel.isCapturing)
            }
        }
    }
    
    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("モード")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Toggle("ローカルプレビュー", isOn: $viewModel.isLoopbackMode)
                    .toggleStyle(.checkbox)
                
                Toggle("ネットワーク送信", isOn: $viewModel.isNetworkMode)
                    .toggleStyle(.checkbox)
            }
        }
    }
    
    private var networkStatus: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("ネットワーク")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 8) {
                // ★ Phase 4: ログイン時に起動トグル
                Toggle("ログイン時に起動", isOn: Binding(
                    get: { loginItemManager.isEnabled },
                    set: { loginItemManager.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                
                Divider()
                    .frame(height: 20)
                
                if viewModel.isListening {
                    Circle()
                        .fill(viewModel.connectedClients > 0 ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    
                    if viewModel.connectedClients > 0 {
                        Text("\(viewModel.connectedClients)クライアント接続中")
                            .font(.caption)
                    } else {
                        Text("ポート5000で待機中")
                            .font(.caption)
                    }
                } else {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                    Text("停止")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Button(viewModel.isListening ? "停止" : "開始") {
                    if viewModel.isListening {
                        viewModel.stopNetworkListener()
                    } else {
                        viewModel.startNetworkListener()
                    }
                }
                .buttonStyle(.bordered)
                
                // QRコード表示ボタン
                Button {
                    showQRCode = true
                } label: {
                    Image(systemName: "qrcode")
                }
                .buttonStyle(.bordered)
                .help("接続用QRコードを表示")
            }
        }
    }
    
    private var statsView: some View {
        HStack(spacing: 20) {
            StatItem(title: "FPS", value: String(format: "%.1f", viewModel.frameRate))
            StatItem(title: "エンコード", value: "\(viewModel.encodedFrameCount)")
            
            if viewModel.isLoopbackMode {
                StatItem(title: "デコード", value: "\(viewModel.decodedFrameCount)")
            }
        }
    }
    
    private var captureButtons: some View {
        HStack(spacing: 12) {
            Button(action: {
                Task {
                    if viewModel.isCapturing {
                        await viewModel.stopCapture()
                    } else {
                        await viewModel.startCapture()
                    }
                }
            }) {
                HStack {
                    Image(systemName: viewModel.isCapturing ? "stop.fill" : "play.fill")
                    Text(viewModel.isCapturing ? "停止" : "開始")
                }
                .frame(width: 100)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isCapturing ? .red : .green)
            .disabled(viewModel.availableDisplays.isEmpty)
        }
    }
    
    // MARK: - Preview Area
    
    private var previewArea: some View {
        ZStack {
            Color.black
            
            if viewModel.isCapturing && viewModel.isLoopbackMode {
                CoordinatedPreviewView(coordinator: viewModel.previewCoordinator)
            } else if viewModel.isCapturing && !viewModel.isLoopbackMode {
                // ネットワークモードのみ（プレビューなし）
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 64))
                        .foregroundColor(.green)
                    
                    Text("ネットワーク送信中")
                        .foregroundColor(.white)
                        .font(.title2)
                    
                    Text("iOSデバイスで接続してください")
                        .foregroundColor(.gray)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "display")
                        .font(.system(size: 64))
                        .foregroundColor(.gray)
                    
                    Text("「開始」をクリックしてキャプチャを開始")
                        .foregroundColor(.gray)
                    
                    if let error = viewModel.captureError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                            .padding(.top, 8)
                    }
                }
            }
        }
    }
    
    // MARK: - QR Code Sheet
    
    private var qrCodeSheet: some View {
        VStack(spacing: 20) {
            Text("接続用QRコード")
                .font(.title2)
                .fontWeight(.bold)
            
            if let connectionString = QRCodeGenerator.generateConnectionString(port: 5100),
               let qrImage = QRCodeGenerator.generateQRCode(from: connectionString, size: CGSize(width: 250, height: 250)) {
                
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 250, height: 250)
                    .background(Color.white)
                    .cornerRadius(8)
                
                if let ip = QRCodeGenerator.getLocalIPAddress() {
                    VStack(spacing: 4) {
                        Text("IPアドレス")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(ip)
                            .font(.system(.title3, design: .monospaced))
                            .fontWeight(.medium)
                            .textSelection(.enabled)
                    }
                }
                
                Text("iPhoneアプリでこのQRコードをスキャンしてください")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    
                    Text("ネットワークに接続されていません")
                        .foregroundColor(.secondary)
                    
                    Text("Wi-Fiに接続してください")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Button("閉じる") {
                showQRCode = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(width: 350, height: 450)
    }
}

// MARK: - Stat Item

struct StatItem: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
        }
    }
}

#Preview {
    ContentView()
}
