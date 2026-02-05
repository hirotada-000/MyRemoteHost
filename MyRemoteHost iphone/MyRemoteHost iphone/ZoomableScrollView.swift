//
//  ZoomableScrollView.swift
//  MyRemoteHost iphone
//
//  ピンチズーム対応のスクロールビュー
//  PNG静止画をズームして高解像度で確認可能にする
//

import SwiftUI
import UIKit

/// ピンチズーム対応のUIScrollViewラッパー
struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    
    let content: Content
    let minZoomScale: CGFloat
    let maxZoomScale: CGFloat
    
    /// ズーム状態通知クロージャ
    var onZoomChanged: ((CGFloat, CGRect) -> Void)?
    
    init(
        minZoom: CGFloat = 1.0,
        maxZoom: CGFloat = 5.0,
        onZoomChanged: ((CGFloat, CGRect) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.minZoomScale = minZoom
        self.maxZoomScale = maxZoom
        self.onZoomChanged = onZoomChanged
        self.content = content()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = minZoomScale
        scrollView.maximumZoomScale = maxZoomScale
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .black
        
        // ダブルタップでズームイン/リセット
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        
        // コンテンツビューをホスト
        let hostingController = UIHostingController(rootView: content)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        
        scrollView.addSubview(hostingController.view)
        context.coordinator.hostedView = hostingController.view
        context.coordinator.scrollView = scrollView
        
        // 制約を設定（初期サイズ）
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hostingController.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            hostingController.view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        
        return scrollView
    }
    
    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // 設定の更新
        scrollView.minimumZoomScale = minZoomScale
        scrollView.maximumZoomScale = maxZoomScale
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableScrollView
        weak var hostedView: UIView?
        weak var scrollView: UIScrollView?
        
        init(_ parent: ZoomableScrollView) {
            self.parent = parent
        }
        
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostedView
        }
        
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            notifyZoomChange(scrollView)
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // ズーム中のスクロールも通知
            if scrollView.zoomScale > 1.0 {
                notifyZoomChange(scrollView)
            }
        }
        
        private func notifyZoomChange(_ scrollView: UIScrollView) {
            let zoomScale = scrollView.zoomScale
            
            // 表示領域を正規化座標（0〜1）で計算
            guard let contentView = hostedView,
                  contentView.bounds.width > 0,
                  contentView.bounds.height > 0 else { return }
            
            let visibleRect = CGRect(
                x: scrollView.contentOffset.x / (contentView.bounds.width * zoomScale),
                y: scrollView.contentOffset.y / (contentView.bounds.height * zoomScale),
                width: scrollView.bounds.width / (contentView.bounds.width * zoomScale),
                height: scrollView.bounds.height / (contentView.bounds.height * zoomScale)
            )
            
            parent.onZoomChanged?(zoomScale, visibleRect)
        }
        
        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = scrollView else { return }
            
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                // ズームアウト（リセット）
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // ズームイン（2.5倍）
                let location = gesture.location(in: hostedView)
                let zoomRect = zoomRectForScale(scale: 2.5, center: location, scrollView: scrollView)
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
        
        private func zoomRectForScale(scale: CGFloat, center: CGPoint, scrollView: UIScrollView) -> CGRect {
            var zoomRect = CGRect.zero
            zoomRect.size.width = scrollView.bounds.size.width / scale
            zoomRect.size.height = scrollView.bounds.size.height / scale
            zoomRect.origin.x = center.x - (zoomRect.size.width / 2.0)
            zoomRect.origin.y = center.y - (zoomRect.size.height / 2.0)
            return zoomRect
        }
    }
}

// MARK: - Preview

#Preview {
    ZoomableScrollView(maxZoom: 5.0) {
        Text("ピンチでズーム可能")
            .font(.largeTitle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.3))
    }
}
