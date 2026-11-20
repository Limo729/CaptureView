import Foundation
import Network
import SwiftUI
import UIKit

/// 把 Apple Pencil 的坐标和压力按行文本发到电脑端（TCP）。
/// 文本协议最省事，电脑那边用 Python 一行行读就行：
///   b,x,y,p  落笔
///   m,x,y,p  移动
///   e,x,y,p  抬笔
/// x/y 是 0~1 的归一化坐标，p 是 0~1 的压力
final class PencilClient: ObservableObject {

    @Published var connected = false
    @Published var lastPressure: Double = 0
    @Published var status = "未连接"

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "local.captureview.pencil")

    var host: String {
        let v = UserDefaults.standard.string(forKey: "penHost") ?? ""
        return v.isEmpty ? "192.168.1.100" : v
    }

    var port: UInt16 {
        let v = UserDefaults.standard.integer(forKey: "penPort")
        return v == 0 ? 47800 : UInt16(clamping: v)
    }

    func connect() {
        disconnect()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.publish(connected: true, status: "已连接 \(self.host):\(self.port)")
            case .failed(let error):
                self.publish(connected: false, status: "连接失败：\(error.localizedDescription)")
            case .waiting(let error):
                self.publish(connected: false, status: "等待中：\(error.localizedDescription)")
            case .cancelled:
                self.publish(connected: false, status: "已断开")
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        connected = false
    }

    func send(kind: Character, x: Double, y: Double, pressure: Double) {
        guard let conn = connection, connected else { return }
        let line = String(format: "%@,%.4f,%.4f,%.3f\n", String(kind), x, y, pressure)
        guard let data = line.data(using: .utf8) else { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    private func publish(connected flag: Bool, status text: String) {
        DispatchQueue.main.async {
            self.connected = flag
            self.status = text
        }
    }
}

/// 只接收 Apple Pencil 的触摸，单指手势仍然交给下面的预览层
final class PencilSurfaceView: UIView {

    weak var client: PencilClient?
    var onPressure: ((Double) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(touches, kind: "b")
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(touches, kind: "m")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(touches, kind: "e")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(touches, kind: "e")
    }

    private func emit(_ touches: Set<UITouch>, kind: Character) {
        guard let touch = touches.first(where: { $0.type == .pencil }) else { return }

        let maxForce = touch.maximumPossibleForce
        let pressure = maxForce > 0 ? min(1.0, max(0.0, Double(touch.force / maxForce))) : 0.0

        let point = touch.preciseLocation(in: self)
        let nx = bounds.width > 1 ? Double(point.x / bounds.width) : 0
        let ny = bounds.height > 1 ? Double(point.y / bounds.height) : 0

        client?.send(kind: kind, x: nx, y: ny, pressure: pressure)
        client?.lastPressure = pressure
        onPressure?(pressure)
    }
}

struct PencilSurface: UIViewRepresentable {
    @ObservedObject var client: PencilClient

    func makeUIView(context: Context) -> PencilSurfaceView {
        let view = PencilSurfaceView()
        view.client = client
        return view
    }

    func updateUIView(_ uiView: PencilSurfaceView, context: Context) {
        uiView.client = client
    }
}
