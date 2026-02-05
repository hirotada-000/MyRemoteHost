//
//  QRCodeScannerView.swift
//  MyRemoteHost iphone
//
//  カメラでQRコードをスキャンするビュー
//

import SwiftUI
import AVFoundation

/// QRコードスキャン結果を通知するデリゲート
protocol QRCodeScannerDelegate: AnyObject {
    func didScanQRCode(_ code: String)
}

/// カメラプレビューを表示するUIView
class QRCodeScannerUIView: UIView {
    
    weak var delegate: QRCodeScannerDelegate?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isRunning = false
    
    /// ★ 重複スキャン防止フラグ（同期的にチェック）
    private var hasScanned = false
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }
    
    func setupAndStart() {
        guard captureSession == nil else {
            startScanning()
            return
        }
        
        // カメラ権限確認
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
            startScanning()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.setupCamera()
                        self?.startScanning()
                    }
                }
            }
        default:
            print("[QRScanner] カメラ権限がありません")
        }
    }
    
    private func setupCamera() {
        captureSession = AVCaptureSession()
        
        guard let captureSession = captureSession,
              let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            print("[QRScanner] カメラデバイスが見つかりません")
            return
        }
        
        do {
            let videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
            
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
            } else {
                print("[QRScanner] ビデオ入力を追加できません")
                return
            }
            
            let metadataOutput = AVCaptureMetadataOutput()
            
            if captureSession.canAddOutput(metadataOutput) {
                captureSession.addOutput(metadataOutput)
                
                metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                metadataOutput.metadataObjectTypes = [.qr]
            } else {
                print("[QRScanner] メタデータ出力を追加できません")
                return
            }
            
            previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewLayer?.videoGravity = .resizeAspectFill
            previewLayer?.frame = bounds
            
            if let previewLayer = previewLayer {
                layer.insertSublayer(previewLayer, at: 0)
            }
            
            print("[QRScanner] カメラセットアップ完了")
            
        } catch {
            print("[QRScanner] カメラ初期化エラー: \(error)")
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
    
    func startScanning() {
        guard let session = captureSession, !session.isRunning else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
            DispatchQueue.main.async {
                self?.isRunning = true
                print("[QRScanner] スキャン開始")
            }
        }
    }
    
    func stopScanning() {
        guard let session = captureSession, session.isRunning else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.stopRunning()
            DispatchQueue.main.async {
                self?.isRunning = false
                print("[QRScanner] スキャン停止")
            }
        }
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension QRCodeScannerUIView: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        
        // ★ 同期的に重複スキャンを防止
        guard !hasScanned else { return }
        
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let stringValue = metadataObject.stringValue else {
            return
        }
        
        // ★ 同期的にフラグを立てる（stopScanningより先に）
        hasScanned = true
        
        // 重複スキャン防止のため一度停止
        stopScanning()
        
        // 触覚フィードバック
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        print("[QRScanner] スキャン成功: \(stringValue)")
        delegate?.didScanQRCode(stringValue)
    }
}

// MARK: - Scanner Sheet View

struct QRCodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onConnect: (String, UInt16) -> Void
    
    @State private var scanError: String?
    @State private var hasScanned = false  // 重複スキャン防止
    
    var body: some View {
        NavigationStack {
            ZStack {
                // カメラプレビュー
                QRCodeScannerViewRepresentable(onScan: handleScannedCode)
                    .ignoresSafeArea()
                
                // オーバーレイ
                VStack {
                    Spacer()
                    
                    // スキャンフレーム
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 250, height: 250)
                        .background(Color.clear)
                    
                    Spacer()
                    
                    // 説明テキスト
                    VStack(spacing: 8) {
                        Text("MacアプリのQRコードをスキャン")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        if let error = scanError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        } else {
                            Text("QRコードをフレーム内に収めてください")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(12)
                    .padding(.bottom, 50)
                }
            }
            .navigationTitle("QRスキャン")
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
    
    private func handleScannedCode(_ code: String) {
        // 重複スキャン防止
        guard !hasScanned else { return }
        hasScanned = true
        
        // フォーマット: myremote://IP:PORT
        guard code.hasPrefix("myremote://") else {
            scanError = "無効なQRコードです"
            hasScanned = false  // リトライ可能に
            return
        }
        
        let connectionInfo = String(code.dropFirst("myremote://".count))
        let components = connectionInfo.split(separator: ":")
        
        guard components.count == 2,
              let port = UInt16(components[1]) else {
            scanError = "接続情報を解析できません"
            hasScanned = false  // リトライ可能に
            return
        }
        
        let host = String(components[0])
        
        onConnect(host, port)
        dismiss()
    }
}

// MARK: - UIViewRepresentable

struct QRCodeScannerViewRepresentable: UIViewRepresentable {
    let onScan: (String) -> Void
    
    func makeUIView(context: Context) -> QRCodeScannerUIView {
        let view = QRCodeScannerUIView()
        view.delegate = context.coordinator
        
        // ビュー作成後に自動でセットアップと開始
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            view.setupAndStart()
        }
        
        return view
    }
    
    func updateUIView(_ uiView: QRCodeScannerUIView, context: Context) {}
    
    static func dismantleUIView(_ uiView: QRCodeScannerUIView, coordinator: Coordinator) {
        uiView.stopScanning()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }
    
    class Coordinator: NSObject, QRCodeScannerDelegate {
        let onScan: (String) -> Void
        
        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }
        
        func didScanQRCode(_ code: String) {
            onScan(code)
        }
    }
}
