import AVFoundation
import Combine
import QuartzCore
import UIKit

/// 采集核心：找 UVC 卡 → 枚举全部格式 → 手动选格式和帧率 → 上屏
final class CaptureController: NSObject, ObservableObject {

    let session = AVCaptureSession()

    @Published var deviceName = "未连接"
    @Published var formats: [FormatDescriptor] = []
    @Published var selectedFormatID: Int?
    @Published var selectedFPS: Double = 60
    @Published var maxFPS: Double = 60
    @Published var currentText = "等待设备…"
    @Published var displayHz = 0

    private let queue = DispatchQueue(label: "local.captureview.session")
    private var deviceInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var displayLink: CADisplayLink?
    private var ticks = 0
    private var tickStart: CFTimeInterval = 0

    private let defaults = UserDefaults.standard

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(deviceHotplug),
                           name: .AVCaptureDeviceWasConnected, object: nil)
        center.addObserver(self, selector: #selector(deviceHotplug),
                           name: .AVCaptureDeviceWasDisconnected, object: nil)
        center.addObserver(self, selector: #selector(sessionError),
                           name: .AVCaptureSessionRuntimeError, object: session)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        displayLink?.invalidate()
    }

    // MARK: - 生命周期

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.setupIfNeeded()
            if !self.session.isRunning { self.session.startRunning() }
        }
        startDisplayLink()
    }

    // MARK: - 设备与格式

    private func setupIfNeeded() {
        guard deviceInput == nil else { return }

        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        guard let found = pickDevice() else {
            session.commitConfiguration()
            setMain(device: "未连接")
            setMain(current: "没有找到采集卡：USB-C 直连采集卡的 USB 口")
            return
        }
        device = found

        let list = loadFormats(found)
        setMain(formats: list)
        setMain(device: found.localizedName.isEmpty ? "UVC 采集卡" : found.localizedName)

        // 恢复上次选择，否则用"帧率优先"的默认
        let savedWidth = defaults.integer(forKey: "fmtWidth")
        let savedHeight = defaults.integer(forKey: "fmtHeight")
        let savedFPS = defaults.double(forKey: "fmtFPS")
        var chosen: FormatDescriptor?
        if savedWidth > 0 {
            chosen = list.first { $0.width == savedWidth && $0.height == savedHeight && $0.maxFPS >= savedFPS - 0.5 }
        }
        if chosen == nil {
            chosen = defaultChoice(in: list)
        }

        if let target = chosen {
            apply(target, fps: savedFPS > 0 ? savedFPS : target.maxFPS)
        }

        do {
            let input = try AVCaptureDeviceInput(device: found)
            if session.canAddInput(input) {
                session.addInput(input)
                deviceInput = input
            } else {
                setMain(current: "无法添加该设备作为输入")
            }
        } catch {
            setMain(current: "打开设备失败：\(error.localizedDescription)")
        }

        session.commitConfiguration()
    }

    private func pickDevice() -> AVCaptureDevice? {
        let external = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        ).devices
        return external.first
    }

    private func loadFormats(_ device: AVCaptureDevice) -> [FormatDescriptor] {
        var list: [FormatDescriptor] = []
        for (index, format) in device.formats.enumerated() {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            var minF = Double.greatestFiniteMagnitude
            var maxF: Double = 0
            for range in format.videoSupportedFrameRateRanges {
                minF = Swift.min(minF, range.minFrameRate)
                maxF = Swift.max(maxF, range.maxFrameRate)
            }
            guard maxF > 0 else { continue }
            if minF == .greatestFiniteMagnitude { minF = 0 }
            list.append(FormatDescriptor(
                id: index,
                width: Int(dims.width),
                height: Int(dims.height),
                codec: codecName(CMFormatDescriptionGetMediaSubType(format.formatDescription)),
                minFPS: minF,
                maxFPS: maxF
            ))
        }
        list.sort { a, b in
            if a.pixels != b.pixels { return a.pixels > b.pixels }
            return a.maxFPS > b.maxFPS
        }
        return list
    }

    /// 默认：优先 120fps，其次 4K60，再其次像素最多的
    private func defaultChoice(in list: [FormatDescriptor]) -> FormatDescriptor? {
        if let high = list.first(where: { $0.maxFPS >= 119 }) {
            return high
        }
        if let uhd = list.first(where: { $0.width >= 3800 && $0.maxFPS >= 55 }) {
            return uhd
        }
        return list.first
    }

    // MARK: - 切换格式 / 帧率

    func select(formatID: Int, fps: Double? = nil) {
        queue.async { [weak self] in
            guard let self = self,
                  let device = self.device,
                  let target = self.formats.first(where: { $0.id == formatID })
            else { return }
            let wanted = fps ?? Swift.min(self.selectedFPS, target.maxFPS)
            self.apply(target, fps: wanted)
        }
    }

    func setFPS(_ fps: Double) {
        queue.async { [weak self] in
            guard let self = self,
                  let device = self.device,
                  let selected = self.selectedFormatID,
                  let current = self.formats.first(where: { $0.id == selected })
            else { return }
            let clamped = Swift.min(Swift.max(fps, Swift.max(current.minFPS, 1)), current.maxFPS)
            self.applyDuration(device: device, format: current, fps: clamped)
            self.setMain(selectedFPS: clamped)
            self.setMain(current: "\(current.title) · \(current.codec) · \(Int(clamped))fps")
        }
    }

    private func apply(_ target: FormatDescriptor, fps: Double) {
        guard let device = device, target.id < device.formats.count else { return }
        session.beginConfiguration()
        let format = device.formats[target.id]
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.unlockForConfiguration()
        } catch {
            session.commitConfiguration()
            setMain(current: "切换格式失败：\(error.localizedDescription)")
            return
        }
        let clamped = Swift.min(Swift.max(fps, Swift.max(target.minFPS, 1)), target.maxFPS)
        applyDuration(device: device, format: target, fps: clamped)
        session.commitConfiguration()

        setMain(selectedFormatID: target.id)
        setMain(maxFPS: target.maxFPS)
        setMain(selectedFPS: clamped)
        setMain(current: "\(target.title) · \(target.codec) · \(Int(clamped))fps")
        defaults.set(target.width, forKey: "fmtWidth")
        defaults.set(target.height, forKey: "fmtHeight")
        defaults.set(target.maxFPS, forKey: "fmtFPS")
    }

    private func applyDuration(device: AVCaptureDevice, format: FormatDescriptor, fps: Double) {
        guard fps > 0 else { return }
        let timescale = CMTimeScale(Swift.max(1, Int(fps.rounded())))
        let duration = CMTime(value: 1, timescale: timescale)
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            setMain(current: "设置帧率失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 热插拔 / 异常

    @objc private func deviceHotplug() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            for input in self.session.inputs {
                self.session.removeInput(input)
            }
            self.session.commitConfiguration()
            self.deviceInput = nil
            self.device = nil

            self.setupIfNeeded()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    @objc private func sessionError() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.deviceInput = nil
            self.device = nil
            self.setupIfNeeded()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    // MARK: - 屏幕刷新率

    private func startDisplayLink() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(self.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        if tickStart == 0 {
            tickStart = now
            return
        }
        ticks += 1
        let elapsed = now - tickStart
        if elapsed >= 1.0 {
            let hz = Int((Double(ticks) / elapsed).rounded())
            ticks = 0
            tickStart = now
            if hz != displayHz { displayHz = hz }
        }
    }

    // MARK: - 主线程发布

    private func setMain(current text: String? = nil,
                         device name: String? = nil,
                         formats list: [FormatDescriptor]? = nil,
                         selectedFormatID id: Int? = nil,
                         maxFPS maxV: Double? = nil,
                         selectedFPS fps: Double? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let t = text { self.currentText = t }
            if let n = name { self.deviceName = n }
            if let l = list { self.formats = l }
            if let i = id { self.selectedFormatID = i }
            if let m = maxV { self.maxFPS = m }
            if let f = fps { self.selectedFPS = f }
        }
    }

    // MARK: - 工具

    /// 用四字符码的字符串形式判断编码，避免 CoreVideo 常量与 FourCharCode 的整型不一致
    private func codecName(_ sub: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((sub >> 24) & 0xFF), UInt8((sub >> 16) & 0xFF),
            UInt8((sub >> 8) & 0xFF), UInt8(sub & 0xFF)
        ]
        let raw = (String(bytes: bytes, encoding: .ascii) ?? "?").trimmingCharacters(in: .whitespaces)
        switch raw {
        case "jpeg", "JPEG", "mjpg", "MJPG":
            return "MJPEG"
        case "420v", "420f":
            return "NV12"
        case "BGRA":
            return "BGRA"
        case "yuvs", "YUY2", "yuys", "2vuy", "yuv2":
            return "YUY2"
        default:
            return raw
        }
    }
}
