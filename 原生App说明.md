# 采集卡 · iPad 原生 App（CaptureView）

iPadOS 原生 App：找到 USB-C 接入的 UVC 采集卡，全屏显示，能手动挑格式和帧率。
目标是把网页那层 60fps 的天花板拆掉，并补上网页给不了的功能。

---

## 功能清单

**输入（真正的格式/帧率控制，不是预设）**

- 枚举设备**全部** `AVCaptureDevice.Format`，逐个列出：分辨率、编码（MJPEG / NV12 / BGRA / YUY2）、支持的帧率区间
- 点任意一项直接切到该格式；切完自动落到该格式支持的帧率
- 帧率可精细调：1–上限的滑杆 + 24/25/30/48/50/60/72/90/100/120/144/165 快捷值
- 启动时恢复上次选的格式和帧率（按宽高匹配，拔插后不丢）

**画面**

- 三种显示方式：等比（黑边）、**拉伸铺满**（非等比，正好填满 2388×1668）、裁切铺满
- 双指捏合缩放（0.5×–8×）、双指拖动平移
- 旋转 0° / 90° / 180° / 270°
- 中心十字 + 三分线 + 内边距框辅助线，可开关
- 一键复位缩放平移；一键回到"按屏幕原分辨率铺满"

**其他**

- 全屏、无状态栏、隐藏系统悬浮元素、屏幕常亮
- 采集卡热插拔自动重连；会话异常自动重建
- 底部读数：采集格式 + 屏幕实际刷新率（判断高刷是否生效就靠这个）
- 拔插/掉线会重建会话，不会黑屏不恢复

**UI**

- iPad 风格：`ultraThinMaterial` 玻璃胶囊状态条 + 四个圆角工具按钮，点画面任意位置可收起/唤出
- 设置面板用系统 Sheet，`medium / large` 两档 detent，顶部三栏分段（输入 / 画面 / 性能）

---

## 目录

```
NativeApp/
├─ project.yml                     # XcodeGen 工程描述（不用手搓 .xcodeproj）
├─ .gitignore
├─ Sources/
│  ├─ App.swift                    # 入口
│  ├─ Models.swift                 # DisplayMode / FormatDescriptor / Viewport
│  ├─ CaptureController.swift      # 设备、格式枚举、切格式、锁帧率、热插拔
│  ├─ PreviewCanvas.swift          # 预览层 + 缩放/平移/旋转 + 拉伸
│  ├─ ContentView.swift            # 全屏布局 + 玻璃工具条 + 辅助线
│  ├─ ControlSheet.swift           # 三栏设置面板
│  └─ Info.plist                   # 含高刷开关
└─ .github/workflows/build-ipa.yml # 云端编译出 IPA
```

---

## 路线 A：有 Mac

```bash
brew install xcodegen
cd NativeApp
xcodegen generate
open CaptureView.xcodeproj
```

1. target → Signing & Capabilities → Team 选你的 Apple ID
2. Bundle Identifier 改成自己的（如 `com.xxx.captureview`）
3. 选 iPad 设备，⌘R

免费 Apple ID 签名 **7 天过期**，到期重连 ⌘R；付费账号一年。

---

## 路线 B：没有 Mac（你选这条）

1. 新建 GitHub 仓库，把 **NativeApp 里所有内容**（含 `.github`、`.gitignore`）放到仓库根目录
2. push 到 `main`，Actions 自动跑；也可在 Actions 页面手动 `Run workflow`
3. 跑完下载 Artifacts 里的 `CaptureView-ipa`，解压得 `CaptureView.ipa`（**未签名**）
4. Windows 装 [Sideloadly](https://sideloadly.io/) + Apple 官网版 iTunes/iCloud（**不要 Microsoft Store 版**）
5. Sideloadly 选设备、拖入 IPA、填 Apple ID、Start
6. iPad：设置 → 通用 → VPN 与设备管理 → 信任证书
7. 打开 App

免费 Apple ID 同样 **7 天**，到期重签。想长期用上开发者账号（$99/年）。

---

## 关于"开机自启"

**做不到，这是系统限制，不是没写。** iPadOS 不允许第三方 App 开机自启，也没有"默认显示器"这种常驻能力。

能接近的做法：

1. 设置 → 辅助功能 → **引导式访问** → 打开；进 App 后连按三次侧边键锁定。这样机器不会被误退出，但每次开机还是要手动点一下图标
2. App 已经做了"恢复上次格式/帧率"，点开就是上次的画面参数，不用重新配

---

## 已知风险

1. **这套代码我这边没法编译验证**（Windows，无 Xcode）。首次 `xcodegen` / `xcodebuild` 若报错，把报错贴我。
2. **能否到 120 取决于卡是否在 AVFoundation 里暴露 120fps 格式**。格式列表会把真相摊开：如果列表里根本没有 `x120` 的项，就是卡不给，App 无能为力。
3. 设 `activeVideoMinFrameDuration` 若超出该格式区间，AVFoundation 会抛异常（崩溃而非报错）。代码只用该格式自身区间内的值，理论上安全。
4. 拉伸铺满会让几何轻微变形（非等比）。要不变形就切"等比"，接受黑边。

---

## 装好之后怎么验收

底部那行读数：

- `2560×1440 · MJPEG · 120fps` + `屏幕 120Hz` → 全通
- `… · 120fps` + `屏幕 60Hz` → ProMotion 没拿到（查 plist 键是否真进了包）
- 格式列表里没有 120 的项 → 采集卡不给，换卡或接受 60
