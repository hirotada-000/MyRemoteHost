//
//  DeviceListView.swift
//  MyRemoteHost iphone
//
//  Phase 4: 商用化 - デバイス管理UI
//  ワンタップ接続を実現するデバイス一覧表示
//

import SwiftUI

/// デバイス一覧ビュー
struct DeviceListView: View {
    @ObservedObject var viewModel: RemoteViewModel
    @State private var showManualConnect = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if viewModel.isDiscoveringHosts {
                    // 発見中
                    ProgressView("デバイスを検索中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.discoveredHosts.isEmpty {
                    // ホストなし
                    emptyStateView
                } else {
                    // ホスト一覧
                    hostListView
                }
            }
            .navigationTitle("マイデバイス")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            viewModel.discoverHosts()
                        } label: {
                            Label("更新", systemImage: "arrow.clockwise")
                        }
                        
                        Button {
                            showManualConnect = true
                        } label: {
                            Label("手動接続", systemImage: "plus")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showManualConnect) {
                ManualConnectView(viewModel: viewModel)
            }
        }
        .onAppear {
            viewModel.discoverHosts()
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("Macが見つかりません")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("MacでMyRemoteHostを起動し、\n画面共有を開始してください")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                viewModel.discoverHosts()
            } label: {
                Text("再検索")
                    .fontWeight(.semibold)
                    .frame(width: 120)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
    
    // MARK: - Host List
    
    private var hostListView: some View {
        List {
            Section {
                ForEach(viewModel.discoveredHosts) { host in
                    DeviceRow(host: host) {
                        viewModel.connectToDiscoveredHost(host)
                    }
                }
            } header: {
                Text("オンラインのMac")
            } footer: {
                Text("同じApple IDでサインインしているMacが表示されます")
            }
            
            // 保存済みホスト
            if !viewModel.savedHosts.isEmpty {
                Section {
                    ForEach(viewModel.savedHosts, id: \.address) { savedHost in
                        SavedHostRow(host: savedHost) {
                            viewModel.hostAddress = savedHost.address
                            viewModel.port = String(savedHost.port)
                            viewModel.connect()
                        }
                    }
                } header: {
                    Text("履歴")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            viewModel.discoverHosts()
        }
    }
}

// MARK: - Device Row

struct DeviceRow: View {
    let host: HostDeviceRecord
    let onConnect: () -> Void
    
    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 15) {
                // デバイスアイコン
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)
                }
                
                // デバイス情報
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.deviceName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        
                        Text("オンライン")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if host.publicIP != nil {
                            Text("• インターネット接続可")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Saved Host Row

struct SavedHostRow: View {
    let host: SavedHost
    let onConnect: () -> Void
    
    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 15) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: "clock")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("\(host.address):\(host.port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Manual Connect View

struct ManualConnectView: View {
    @ObservedObject var viewModel: RemoteViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("IPアドレス", text: $viewModel.hostAddress)
                        .keyboardType(.numbersAndPunctuation)
                        .autocapitalization(.none)
                    
                    TextField("ポート", text: $viewModel.port)
                        .keyboardType(.numberPad)
                } header: {
                    Text("接続先")
                }
                
                Section {
                    Button {
                        viewModel.connect()
                        dismiss()
                    } label: {
                        Text("接続")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.hostAddress.isEmpty || viewModel.port.isEmpty)
                }
            }
            .navigationTitle("手動接続")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
            }
        }
    }
}
