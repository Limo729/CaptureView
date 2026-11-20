import Foundation
import Network
import SwiftUI
import UIKit

/// 把 App 内部算出的「视频画面归一化坐标」交给笔控件。
/// 这里不缓存任何画面实例/变换：笔落下的那一刻直接问当前那个真正在屏上的画面层，
/// 所以改旋转、改镜像、改缩放之后不会用到旧的状态。
final class PenMapper: ObservableObject {
    weak var target: PreviewCanvasView?

    func map(_ windowPoint: CGPoint) -> CGPoint {
        guard let view = target else { return CGPoint(x: 0.5, y: 0.5) }
        return view.normalizedVideoPoint(windowPoint: windowPoint)
    }
}

/// 把 Apple Pencil 的坐标和压力按行文本发到电脑端（TCP）。
/// 文本协议：
///   b,x,y,p  落笔
///   m,x,y,p  移动
///   e,x,y,p  抬笔
/// x/y 是视频画面里的 0~1 坐标，p 是 0~1 的压力
final class PencilClient: ObservableObject {

    @Published var connected = false
    @Published var lastPressure: Double = 0
    @Published var status = "未连接"
    /// 每秒实际发出的采样条数，用来确认是不是真的跑到了 120 条/秒
    @Published var sampleRate: Double = 0

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "local.captureview.pencil", qos: .userInteractive)
    private var retryWork: DispatchWorkItem?
    private var wantConnection = false
    private var rateTimer: DispatchSourceTimer?
    private var sampleCount = 0
    private var lastRateStamp = Date()

    var host: String {
        let v = UserDefaults.standard.string(forKey: "penHost") ?? ""
        return v.isEmpty ? "192.168.1.100" : v
    }

    var port: UInt16 {
        let v = UserDefaults.standard.integer(forKey: "penPort")
        return v == 0 ? 47800 : UInt16(clamping: v)
    }

    func connect() {
        wantConnection = true
        retryWork?.cancel()
        openConnection()
        startRateTimer()
    }

    private func openConnection() {
        connection?.cancel()
        connection = nil
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        // noDelay 关掉 Nagle：笔的坐标是一串小包，Nagle 会攒包再发，体感就是「跟不上手」
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 3
        let params = NWParameters(tls: nil, tcp: tcp)

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.publish(connected: true, status: "已连接 \(self.host):\(self.port)")
            case .failed(let error):
                self.publish(connected: false, status: "连接失败：\(error.localizedDescription)")
                self.scheduleRetry()
            case .waiting(let error):
                self.publish(connected: false, status: "等待中：\(error.localizedDescription)")
                self.scheduleRetry()
            case .cancelled:
                self.publish(connected: false, status: "已断开")
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    /// 一次发送就把一整批采样拼成一个包发出去，避免每条一次系统调用
    func sendBatch(_ lines: [String]) {
        guard wantConnection, connected, let conn = connection, !lines.isEmpty else { return }
        var payload = lines.joined(separator: "\n")
        payload.append("\n")
        guard let data = payload.data(using: .utf8) else { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
        sampleCount += lines.count
    }

    func disconnect() {
        wantConnection = false
        retryWork?.cancel()
        rateTimer?.cancel()
        rateTimer = nil
        connection?.cancel()
        connection = nil
        publish(connected: false, status: "已断开")
    }

    private func scheduleRetry() {
        guard wantConnection else { return }
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.wantConnection else { return }
            self.openConnection()
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func startRateTimer() {
        guard rateTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = Date()
            let dt = max(0.001, now.timeIntervalSince(self.lastRateStamp))
            let rate = Double(self.sampleCount) / dt
            self.sampleCount = 0
            self.lastRateStamp = now
            DispatchQueue.main.async { self.sampleRate = rate }
        }
        timer.resume()
        rateTimer = timer
    }

    private func publish(connected flag: Bool, status text: String) {
        DispatchQueue.main.async {
            self.connected = flag
            self.status = text
        }
    }
}

/// 只接收 Apple Pencil 的触摸；用 coalescedTouches 把一帧里攒下的采样全部发出去，
/// 这样 iPad 上 120Hz 的手写采样不会因为界面刷新被丢成一帧一个点
final class PencilSurfaceView: UIView {

    weak var client: PencilClient?
    var mapper: PenMapper?
    var onPressure: ((Double) -> Void)?

    private var pencilTouch: UITouch?
    private var pressed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonSetup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonSetup()
    }

    private func commonSetup() {
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        isUserInteractionEnabled = true
    }

    /// 不允许在边缘被判成「点在外面」，笔划出屏幕边缘也照样收事件
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first(where: { $0.type == .pencil }) else { return }
        pencilTouch = t
        pressed = true
        client?.sendBatch([line("b", t)])
        emitPressure(t)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = pencilTouch ?? touches.first(where: { $0.type == .pencil }) else { return }
        pencilTouch = t

        var lines: [String] = []
        // 之前被判成取消（比如系统边缘手势抢了一下），这里自动补一次按下，
        // 笔划就不会莫名其妙断掉
        if !pressed {
            pressed = true
            lines.append(line("b", t))
        }

        if let samples = event?.coalescedTouches(for: t), !samples.isEmpty {
            for s in samples {
                lines.append(line("m", s))
            }
        } else {
            lines.append(line("m", t))
        }

        client?.sendBatch(lines)
        emitPressure(t)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first(where: { $0.type == .pencil }) ?? pencilTouch else { return }
        client?.sendBatch([line("e", t)])
        pressed = false
        pencilTouch = nil
        client?.lastPressure = 0
        onPressure?(0)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first(where: { $0.type == .pencil }) ?? pencilTouch else { return }
        // 只抬一下笔，等下一次 moved 会自动补按下，避免一次系统手势就把整笔画废
        if pressed {
            client?.sendBatch([line("e", t)])
        }
        pressed = false
    }

    private func line(_ kind: String, _ t: UITouch) -> String {
        let windowPoint = t.location(in: nil)
        var uv = mapper?.map(windowPoint) ?? CGPoint(x: 0.5, y: 0.5)
        uv.x = min(1.0, max(0.0, uv.x))
        uv.y = min(1.0, max(0.0, uv.y))

        let maxForce = t.maximumPossibleForce
        let pressure = maxForce > 0 ? min(1.0, max(0.0, Double(t.force / maxForce))) : 0.0
        return String(format: "%@,%.5f,%.5f,%.3f", kind, Double(uv.x), Double(uv.y), pressure)
    }

    private func emitPressure(_ t: UITouch) {
        let maxForce = t.maximumPossibleForce
        let pressure = maxForce > 0 ? min(1.0, max(0.0, Double(t.force / maxForce))) : 0.0
        client?.lastPressure = pressure
        onPressure?(pressure)
    }
}

struct PencilSurface: UIViewRepresentable {
    @ObservedObject var client: PencilClient
    var mapper: PenMapper

    func makeUIView(context: Context) -> PencilSurfaceView {
        let view = PencilSurfaceView()
        view.client = client
        view.mapper = mapper
        return view
    }

    func updateUIView(_ uiView: PencilSurfaceView, context: Context) {
        uiView.client = client
        uiView.mapper = mapper
    }
}

