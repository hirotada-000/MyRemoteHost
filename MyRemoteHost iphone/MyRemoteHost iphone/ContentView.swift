//
//  ContentView.swift
//  MyRemoteHost iphone
//
//  リモートデスクトップクライアントのメインUI
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = RemoteViewModel()
    @State private var showQRScanner = false
    @State private var pendingConnection: (host: String, port: UInt16)?
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 背景
                Color.black.ignoresSafeArea()
                
                if viewModel.isConnected {
                    // 接続中：ゲームパッドUI
                    GamepadView(viewModel: viewModel)
                } else if viewModel.isWaitingForAuth {
                    // 認証待機中
                    authWaitingView
                } else if viewModel.authDenied {
                    // 認証拒否
                    authDeniedView
                } else {
                    // 未接続：接続設定
                    connectionView
                }
            }
            .navigationTitle("MyRemote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.isConnected || viewModel.isWaitingForAuth {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("切断") {
                            viewModel.disconnect()
                        }
                        .foregroundColor(.red)
                    }
                }
            }
        }
        .sheet(isPresented: $showQRScanner) {
            QRCodeScannerSheet { host, port in
                // 接続情報を一時保存（シートが閉じた後に接続）
                pendingConnection = (host, port)
            }
        }
        .onChange(of: showQRScanner) { _, isPresented in
            print("[ContentView] showQRScanner changed: \(isPresented)")  // ★ デバッグログ
            if !isPresented, let conn = pendingConnection {
                print("[ContentView] pendingConnection found: \(conn.host):\(conn.port)")  // ★ デバッグログ
                viewModel.hostAddress = conn.host
                viewModel.port = String(conn.port)
                pendingConnection = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    print("[ContentView] calling viewModel.connect()")  // ★ デバッグログ
                    viewModel.connect()
                }
            }
        }
    }
    
    // MARK: - Authentication Views
    
    private var authWaitingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(2)
                .tint(.white)
            
            Text("Mac側で認証してください")
                .font(.title2)
                .foregroundColor(.white)
            
            Text(viewModel.hostAddress)
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
    
    private var authDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)
            
            Text("接続が拒否されました")
                .font(.title2)
                .foregroundColor(.white)
            
            Button("再試行") {
                viewModel.authDenied = false
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    // MARK: - Connection View
    
    private var connectionView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // アイコン
            Image(systemName: "desktopcomputer")
                .font(.system(size: 80))
                .foregroundColor(.blue)
            
            Text("リモートデスクトップ")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            // QRスキャンボタン（大きく目立つ）
            Button(action: {
                showQRScanner = true
            }) {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.title2)
                    Text("QRコードで接続")
                }
                .frame(width: 250, height: 55)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(28)
            }
            
            // ★ 最近の接続先
            if !viewModel.savedHosts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近の接続先")
                        .font(.headline)
                        .foregroundColor(.gray)
                        .padding(.horizontal, 40)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(viewModel.savedHosts) { host in
                                savedHostButton(host)
                            }
                        }
                        .padding(.horizontal, 40)
                    }
                }
            }
            
            // または
            HStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(height: 1)
                Text("または")
                    .font(.caption)
                    .foregroundColor(.gray)
                Rectangle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(height: 1)
            }
            .padding(.horizontal, 40)
            
            // 手動入力フィールド
            VStack(spacing: 16) {
                TextField("ホストアドレス (例: 192.168.1.100)", text: $viewModel.hostAddress)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                
                TextField("ポート", text: $viewModel.port)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
            }
            .padding(.horizontal, 40)
            
            // エラー表示
            if let error = viewModel.connectionError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            // 手動接続ボタン
            Button(action: {
                viewModel.connect()
            }) {
                HStack {
                    if viewModel.isConnecting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    }
                    Text(viewModel.isConnecting ? "接続中..." : "手動で接続")
                }
                .frame(width: 200, height: 50)
                .background(viewModel.isConnecting ? Color.gray : Color.gray.opacity(0.3))
                .foregroundColor(.white)
                .cornerRadius(25)
                .overlay(
                    RoundedRectangle(cornerRadius: 25)
                        .stroke(Color.gray, lineWidth: 1)
                )
            }
            .disabled(viewModel.isConnecting)
            
            Spacer()
            
            // 使い方
            VStack(spacing: 8) {
                Text("使い方")
                    .font(.headline)
                    .foregroundColor(.gray)
                
                Text("1. Macで MyRemoteHost を起動\n2. QRコードボタンをクリック\n3. このアプリでスキャン")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 40)
        }
    }
    
    /// 保存済みホストボタン
    private func savedHostButton(_ host: SavedHost) -> some View {
        Button(action: {
            viewModel.connectToSavedHost(host)
        }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "desktopcomputer")
                        .foregroundColor(.blue)
                    Text(host.name)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                Text("\(host.address):\(host.port)")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(12)
        }
        .contextMenu {
            Button(role: .destructive) {
                viewModel.deleteSavedHost(host)
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }
    
    // MARK: - Connected View
    
    private var connectedView: some View {
        VStack(spacing: 0) {
            // 映像プレビュー（タッチ操作対応）
            GeometryReader { geometry in
                CoordinatedPreviewView(coordinator: viewModel.previewCoordinator)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())  // 全体をタップ可能に
                    // タップでクリック
                    .onTapGesture { location in
                        let normalizedX = Float(location.x / geometry.size.width)
                        let normalizedY = Float(location.y / geometry.size.height)
                        
                        // マウス移動 → クリック
                        viewModel.inputSender.sendMouseMove(normalizedX: normalizedX, normalizedY: normalizedY)
                        viewModel.inputSender.sendMouseDown(button: .left)
                        viewModel.inputSender.sendMouseUp(button: .left)
                    }
                    // ドラッグでマウス移動
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let normalizedX = Float(value.location.x / geometry.size.width)
                                let normalizedY = Float(value.location.y / geometry.size.height)
                                viewModel.inputSender.sendMouseMove(normalizedX: normalizedX, normalizedY: normalizedY)
                            }
                    )
            }
            
            // ステータスバー
            HStack {
                Label("\(String(format: "%.1f", viewModel.frameRate)) FPS", systemImage: "speedometer")
                
                Spacer()
                
                Label("\(viewModel.decodedFrameCount) フレーム", systemImage: "film")
            }
            .font(.caption)
            .foregroundColor(.white)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.7))
        }
    }
}

#Preview {
    ContentView()
}
