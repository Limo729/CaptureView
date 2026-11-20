import AVFoundation
import SwiftUI
import UIKit

struct PreviewCanvas: UIViewRepresentable {
    let session: AVCaptureSession
    let mode: DisplayMode
    let rotation: Double
    let mirrorH: Bool
    let mirrorV: Bool
    let allowGestures: Bool
    let videoSize: CGSize
    var mapper: PenMapper
    @ObservedObject var viewport: Viewport

    func makeCoordinator() -> Coordinator {
        Coordinator(viewport: viewport)
    }

    final class Coordinator {
        let viewport: Viewport
        init(viewport: Viewport) { self.viewport = viewport }
    }

    func makeUIView(context: Context) -> PreviewCanvasView {
        let view = PreviewCanvasView()
        view.attach(session)
        view.mapper = mapper
        view.onViewportChange = { zoom, pan in
            context.coordinator.viewport.zoom = zoom
            context.coordinator.viewport.pan = pan
        }
        return view
    }

    func updateUIView(_ uiView: PreviewCanvasView, context: Context) {
        uiView.setGesturesEnabled(allowGestures)
        uiView.apply(
            mode: mode,
            rotation: rotation,
            mirrorH: mirrorH,
            mirrorV: mirrorV,
            videoSize: videoSize,
            zoom: viewport.zoom,
            pan: viewport.pan,
            resetToken: viewport.resetToken
        )
    }
}

/// 画面容器：预览层放在一个中间层里，缩放/旋转作用在中间层，
/// 避免直接改 AVCaptureVideoPreviewLayer 的 transform（那样在部分系统版本上会被忽略）
final class PreviewCanvasView: UIView {

    private let canvasLayer = CALayer()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    var onViewportChange: ((CGFloat, CGSize) -> Void)?

    private var zoom: CGFloat = 1
    private var pan: CGSize = .zero
    private var rotation: CGFloat = 0
    private var mirrorH = false
    private var mirrorV = false
    private var mode: DisplayMode = .stretch
    private var videoSize = CGSize(width: 2560, height: 1440)
    private var lastToken = 0

    /// 笔的坐标换算入口；每次布局/应用变换都把自己登记进去，保证拿到的是当前在屏的这一份
    weak var mapper: PenMapper?

    private var startZoom: CGFloat = 1
    private var startPan: CGSize = .zero

    private var pinchRecognizer: UIPinchGestureRecognizer?
    private var panRecognizer: UIPanGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonSetup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonSetup()
    }

    private func commonSetup() {
        backgroundColor = .black
        clipsToBounds = true
        previewLayer.videoGravity = .resize
        layer.addSublayer(canvasLayer)
        canvasLayer.addSublayer(previewLayer)
        setupGestures()
    }

    func attach(_ session: AVCaptureSession) {
        previewLayer.session = session
    }

    private func setupGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pinch)
        addGestureRecognizer(pan)
        pinchRecognizer = pinch
        panRecognizer = pan
    }

    /// 设置里可以关掉双指手势，避免误触；关掉时点击/滑动不会被吃掉
    func setGesturesEnabled(_ enabled: Bool) {
        pinchRecognizer?.isEnabled = enabled
        panRecognizer?.isEnabled = enabled
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            startZoom = zoom
        case .changed:
            zoom = Swift.min(Swift.max(startZoom * gesture.scale, 0.5), 8)
            applyTransform()
            onViewportChange?(zoom, pan)
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            startPan = pan
        case .changed:
            let t = gesture.translation(in: self)
            pan = CGSize(width: startPan.width + t.x, height: startPan.height + t.y)
            applyTransform()
            onViewportChange?(zoom, pan)
        default:
            break
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mapper?.target = self
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = layerSize()
        canvasLayer.bounds = CGRect(origin: .zero, size: size)
        canvasLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)

        // 预览层是 canvasLayer 的子层，它的 position 用的是父层坐标系，
        // 必须按 canvasLayer 自己的尺寸算中心，不能再用屏幕中心
        previewLayer.bounds = CGRect(origin: .zero, size: size)
        previewLayer.position = CGPoint(x: size.width / 2, y: size.height / 2)
        CATransaction.commit()
        applyTransform()
    }

    /// 旋转 90°/270° 时把图层宽高互换，
    /// 这样图层转过来正好覆盖整个屏幕，拉伸铺满不留黑边
    private func layerSize() -> CGSize {
        let isQuarterTurn = abs(sin(rotation)) > 0.999
        return isQuarterTurn
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
    }

    func apply(mode newMode: DisplayMode, rotation degrees: Double,
               mirrorH newMirrorH: Bool, mirrorV newMirrorV: Bool,
               videoSize newVideoSize: CGSize = CGSize(width: 2560, height: 1440),
               zoom newZoom: CGFloat, pan newPan: CGSize, resetToken: Int) {

        if resetToken != lastToken {
            lastToken = resetToken
            zoom = 1
            pan = .zero
        }
        if mode != newMode {
            mode = newMode
            previewLayer.videoGravity = newMode.gravity
        }
        if newVideoSize.width > 1, newVideoSize.height > 1, videoSize != newVideoSize {
            videoSize = newVideoSize
        }
        if abs(zoom - newZoom) > 0.002 { zoom = newZoom }
        if abs(pan.width - newPan.width) > 0.5 || abs(pan.height - newPan.height) > 0.5 {
            pan = newPan
        }
        let radians = CGFloat(degrees * Double.pi / 180)
        if abs(rotation - radians) > 0.001 {
            rotation = radians
            // 旋转角度变了，图层宽高可能要互换，重新布局
            setNeedsLayout()
        }
        if mirrorH != newMirrorH { mirrorH = newMirrorH }
        if mirrorV != newMirrorV { mirrorV = newMirrorV }

        mapper?.target = self
        applyTransform()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { mapper?.target = self }
    }

    private func applyTransform() {
        var t = CGAffineTransform(translationX: pan.width, y: pan.height)
        t = t.scaledBy(x: zoom, y: zoom)
        t = t.rotated(by: rotation)
        // 镜像先作用在画面坐标系里，再叠加平移/缩放/旋转，
        // 这样拖动手感和未镜像时一致
        let mirror = CGAffineTransform(scaleX: mirrorH ? -1 : 1, y: mirrorV ? -1 : 1)
        t = mirror.concatenating(t)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvasLayer.setAffineTransform(t)
        CATransaction.commit()
    }

    // MARK: - 笔坐标换算

    /// 窗口坐标 → 视频画面里的 0~1 坐标。
    /// 路径：窗口点 → 本视图坐标 → canvasLayer 内容坐标（自动扣掉旋转/镜像/缩放/平移）
    ///      → 按 videoGravity 扣掉留边 → 归一化。
    /// 只要最终归一化到视频画面，电脑端就是 1:1 对应桌面像素，不需要再手工加偏移。
    func normalizedVideoPoint(windowPoint: CGPoint) -> CGPoint {
        if needsLayout { layoutIfNeeded() }
        let local = convert(windowPoint, from: nil)
        let inCanvas = canvasLayer.convert(local, from: layer)
        let content = videoRect(in: CGRect(origin: .zero, size: canvasLayer.bounds.size))
        guard content.width > 1, content.height > 1 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (inCanvas.x - content.minX) / content.width,
                       y: (inCanvas.y - content.minY) / content.height)
    }

    /// 视频画面在 canvasLayer 里实际占的矩形；等比模式会有黑边，裁切模式会超出
    private func videoRect(in box: CGRect) -> CGRect {
        guard videoSize.width > 1, videoSize.height > 1 else { return box }
        let videoAspect = videoSize.width / videoSize.height
        let boxAspect = box.width / box.height
        switch mode {
        case .stretch:
            return box
        case .aspect:
            if videoAspect > boxAspect {
                let h = box.width / videoAspect
                return CGRect(x: box.minX, y: box.midY - h / 2, width: box.width, height: h)
            }
            let w = box.height * videoAspect
            return CGRect(x: box.midX - w / 2, y: box.minY, width: w, height: box.height)
        case .crop:
            if videoAspect > boxAspect {
                let w = box.height * videoAspect
                return CGRect(x: box.midX - w / 2, y: box.minY, width: w, height: box.height)
            }
            let h = box.width / videoAspect
            return CGRect(x: box.minX, y: box.midY - h / 2, width: box.width, height: h)
        }
    }
}
