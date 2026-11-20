// Device sync screens (docs/SYNC.md): Settings › Devices, the linking sheet (intro, show a code,
// enter a code, scan a QR, linked), the first-run welcome and the one-time Home hint. State and
// Bonjour live in App/DeviceSyncStore.swift; the words in Core/DeviceSync.swift (`DeviceSyncText`).
import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: Settings › Devices

struct DevicesSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let d = app.devices
        let s = d.status
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Devices").font(Typo.font(18, .bold)).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .top, spacing: Space.m) {
                    DeviceTile(linked: s.paired, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(DeviceSyncText.title(s)).font(Typo.font(16, .bold)).lineLimit(2)
                            .accessibilityIdentifier("devices-title")
                        if s.paired {
                            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                                let line = DeviceSyncText.statusLine(s, now: d.nowOverride ?? ctx.date.timeIntervalSince1970)
                                HStack(spacing: 6) {
                                    Circle().fill(line.hasPrefix("Synced") || s.syncing ? Palette.accent : Palette.dim).frame(width: 7, height: 7)
                                    Text(line).font(Typo.font(14)).foregroundStyle(Palette.meta)
                                }
                            }
                            .accessibilityIdentifier("devices-status")
                            if let p = DeviceSyncText.pending(s.pending) {
                                Text(p).font(Typo.font(13)).foregroundStyle(Palette.subdued)
                            }
                        } else {
                            Text(DeviceSyncText.notLinkedLine).font(Typo.font(14)).foregroundStyle(Palette.subdued)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if s.paired, s.lastError != nil {
                    HStack(alignment: .top, spacing: Space.s) {
                        Icon(name: "warning-circle", size: 18).foregroundStyle(Palette.negative)
                        Text(DeviceSyncText.errorLine).font(Typo.font(13)).foregroundStyle(Palette.subdued)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                HStack(spacing: Space.s) {
                    if s.paired {
                        DevicePill(title: s.syncing ? "Syncing…" : "Sync now", style: .light, busy: s.syncing) { d.syncNow { app.fail($0) } }
                            .accessibilityIdentifier("devices-sync-now")
                        DevicePill(title: "Unlink", style: .outline) {
                            app.confirm = ConfirmRequest(title: DeviceSyncText.unlinkTitle(s.peers), message: DeviceSyncText.unlinkMessage,
                                                         action: "Unlink") {
                                d.unlink(done: { app.showToast("Unlinked") }, fail: { app.fail($0) })
                            }
                        }
                        .accessibilityIdentifier("devices-unlink")
                    } else {
                        DevicePill(title: "Link a device", style: .accent) { d.open() }
                            .accessibilityIdentifier("devices-link")
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(Space.l)
            .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Palette.highlight))
        }
        .padding(.horizontal, Space.gutter).padding(.top, Space.s).padding(.bottom, Space.l)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-devices")
    }
}

/// The devices glyph on the brand tile; a small accent check once linked.
struct DeviceTile: View {
    var linked = false
    var size: CGFloat = 44
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [Palette.accentTile, Palette.accentTileDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Icon(name: "devices", size: size * 0.55).foregroundStyle(Palette.accentText))
            .overlay(alignment: .bottomTrailing) {
                if linked {
                    Circle().fill(Palette.accent).frame(width: size * 0.4, height: size * 0.4)
                        .overlay(Icon(name: "check", size: size * 0.22).foregroundStyle(.black))
                        .overlay(Circle().stroke(Palette.highlight, lineWidth: 2))
                        .offset(x: size * 0.12, y: size * 0.12)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A compact capsule button (Settings card, Home hint).
struct DevicePill: View {
    enum Style { case accent, light, outline }
    let title: String
    var style: Style = .accent
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini).tint(style == .outline ? Palette.text : .black) }
                Text(title).font(Typo.font(14, .bold))
            }
            .foregroundStyle(style == .outline ? Palette.text : .black)
            .padding(.horizontal, Space.l).frame(height: 36)
            .background {
                switch style {
                case .accent: Capsule().fill(Palette.accent)
                case .light: Capsule().fill(Palette.text)
                case .outline: Capsule().stroke(Palette.dim, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .disabled(busy)
    }
}

// MARK: the linking sheet

struct LinkDeviceSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let d = app.devices
        VStack(spacing: 0) {
            HStack {
                if d.step != .intro && d.step != .success {
                    Button { d.go(.intro) } label: { Icon(name: "caret-left", size: 22).frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("link-back")
                }
                Spacer()
                Button { d.closed() } label: { Icon(name: "x", size: 20).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("link-close")
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, Space.s).padding(.top, Space.m)
            Group {
                switch d.step {
                case .intro: LinkIntroStep()
                case .showCode: ShowCodeStep()
                case .enterCode: EnterCodeStep()
                case .scan: ScanCodeStep()
                case .success: LinkedStep()
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .foregroundStyle(Palette.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("link-device")
    }
}

/// Mac and iPhone, side by side (the sheet's and the welcome's picture).
private struct DevicesHero: View {
    var size: CGFloat = 72
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Palette.accent.opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: size * 1.3))
                .frame(width: size * 2.6, height: size * 2.6)
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: size, weight: .light))
                .foregroundStyle(Palette.accentText)
        }
        .frame(height: size * 1.9)
        .accessibilityHidden(true)
    }
}

private struct LinkIntroStep: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let d = app.devices
        VStack(spacing: 0) {
            Spacer(minLength: Space.s)
            DevicesHero()
            OnboardHeader(title: DeviceSyncText.introTitle, line: DeviceSyncText.introBody, center: true)
                .padding(.top, Space.l)
            Spacer(minLength: Space.xl)
            VStack(spacing: Space.m) {
                OnboardPrimaryButton(title: "Show code") { d.go(.showCode) }
                    .accessibilityIdentifier("link-show-code")
                OnboardSecondaryButton(title: "Enter code") { d.go(.enterCode) }
                    .accessibilityIdentifier("link-enter-code")
                OnboardSecondaryButton(title: "Scan QR code") { d.go(.scan) }
                    .accessibilityIdentifier("link-scan")
                HStack(alignment: .top, spacing: Space.s) {
                    Icon(name: "wifi-high", size: 16).foregroundStyle(Palette.subdued)
                    Text(DeviceSyncText.localNetworkLine).font(Typo.font(13)).foregroundStyle(Palette.subdued)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Space.s)
            }
        }
    }
}

private struct ShowCodeStep: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let d = app.devices
        VStack(spacing: Space.l) {
            Text("Enter this code on your other device").font(Typo.font(22, .bold)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s)
                .accessibilityAddTraits(.isHeader)
            if let end = d.codeEnd {
                Spacer(minLength: 0)
                CodeEndedView(end: end) { d.showCode() }
                Spacer(minLength: 0)
            } else if let p = d.shown {
                Text(DeviceSyncText.code(p.code))
                    .font(Typo.font(52, .bold)).monospacedDigit().kerning(4)
                    .foregroundStyle(Palette.text)
                    .accessibilityLabel(p.code.map(String.init).joined(separator: " "))
                    .accessibilityIdentifier("link-code")
                QRTile(payload: p.qr, size: 176)
                Text("Or scan this code with your other iPhone's camera.").font(Typo.font(13)).foregroundStyle(Palette.subdued)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
                VStack(spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        ProgressView().tint(Palette.accentText)
                        Text("Waiting for your other device…").font(Typo.font(15, .medium))
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = p.expiresAt - (d.nowOverride ?? ctx.date.timeIntervalSince1970)
                        Text("Code expires in \(DeviceSyncText.countdown(left))").font(Typo.font(13)).foregroundStyle(Palette.subdued)
                            .monospacedDigit()
                    }
                }
                .task(id: p.code) {
                    while !Task.isCancelled {
                        if d.nowOverride == nil, Date().timeIntervalSince1970 >= p.expiresAt { d.codeExpired(); return }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            } else if let e = d.error {
                Spacer(minLength: 0)
                PairingErrorRow(error: e)
                OnboardPrimaryButton(title: "Show a new code") { d.showCode() }
                Spacer(minLength: 0)
            } else {
                Spacer()
                ProgressView().tint(Palette.text)
                Spacer()
            }
            OnboardSecondaryButton(title: "Cancel") { d.go(.intro) }
                .accessibilityIdentifier("link-cancel")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("link-show")
    }
}

private struct CodeEndedView: View {
    let end: DeviceSyncStore.CodeEnd
    let again: () -> Void
    var body: some View {
        VStack(spacing: Space.l) {
            Icon(name: end == .expired ? "clock" : "warning-circle", size: 48).foregroundStyle(Palette.subdued)
            Text(end == .expired ? "This code has expired." : "Too many wrong tries. Show a new code to try again.")
                .font(Typo.font(17, .medium)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("link-code-ended")
            OnboardPrimaryButton(title: "Show a new code", action: again)
                .accessibilityIdentifier("link-new-code")
        }
    }
}

/// A QR code drawn by CoreImage, on a white tile so any camera reads it.
struct QRTile: View {
    let payload: String
    var size: CGFloat = 176
    var body: some View {
        Group {
            if let img = QRTile.image(payload) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white))
        .accessibilityLabel("QR code")
        .accessibilityIdentifier("link-qr")
    }

    static func image(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private struct EnterCodeStep: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        let d = app.devices
        VStack(spacing: Space.l) {
            Text("Enter the code from your other device").font(Typo.font(22, .bold)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s)
                .accessibilityAddTraits(.isHeader)
            CodeBoxes(digits: d.digits, failed: d.error != nil)
                .overlay {
                    // The real field: invisible over the boxes, so a tap focuses it and a long press pastes.
                    TextField("", text: Binding(get: { d.digits }, set: { d.typed($0) }))
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .foregroundStyle(.clear).tint(.clear)
                        .focused($focused)
                        .accessibilityLabel("Code")
                        .accessibilityIdentifier("link-code-field")
                }
                .padding(.top, Space.s)
            if let e = d.error {
                PairingErrorRow(error: e)
            } else {
                PasteButton(payloadType: String.self) { strings in
                    guard let s = strings.first else { return }
                    Task { @MainActor in d.typed(s) }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .tint(Palette.elevatedHighlight)
            }
            Spacer(minLength: 0)
            OnboardPrimaryButton(title: d.busy ? "Linking…" : "Link", busy: d.busy, enabled: d.digits.count == 6) { d.join() }
                .accessibilityIdentifier("link-join")
        }
        .onAppear {
            // Not under tests: the keyboard would move the snapshot.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { focused = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("link-enter")
    }
}

/// Six boxes, a gap after the third (the code reads "482 913"); the next box to fill is outlined.
struct CodeBoxes: View {
    let digits: String
    var failed = false
    var body: some View {
        let chars = Array(digits)
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { i in
                let active = i == chars.count && !failed
                Text(i < chars.count ? String(chars[i]) : "")
                    .font(Typo.font(28, .bold)).monospacedDigit()
                    .frame(width: 46, height: 58)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.elevatedHighlight))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(failed ? Palette.negative : active ? Palette.accent : Color.clear, lineWidth: 2))
                    .padding(.leading, i == 3 ? 10 : 0)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A failed link in plain words, with a way to fix it where there is one.
private struct PairingErrorRow: View {
    let error: PairingError
    var body: some View {
        VStack(spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.s) {
                Icon(name: "warning-circle", size: 20).foregroundStyle(Palette.negative)
                Text(error.message).font(Typo.font(15)).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Palette.negative.opacity(0.12)))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("link-error")
            if error.kind == .localNetwork {
                DevicePill(title: "Open Settings", style: .light) {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                }
                .accessibilityIdentifier("link-open-settings")
            }
        }
    }
}

private struct ScanCodeStep: View {
    @Environment(AppModel.self) private var app
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var serial = 0

    var body: some View {
        let d = app.devices
        VStack(spacing: Space.l) {
            Text("Scan the QR code on your other device").font(Typo.font(22, .bold)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s)
                .accessibilityAddTraits(.isHeader)
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Palette.elevatedHighlight)
                switch access {
                case .authorized:
                    if AVCaptureDevice.default(for: .video) != nil {
                        QRScannerView { code in
                            if let qr = CodeEntry.pairLink(in: code) { d.digits = CodeEntry.read(qr).digits; d.join(qr: qr) }
                        }
                        .id(serial)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        ViewfinderCorners().padding(28)
                    } else {
                        Text("No camera on this device.").font(Typo.font(15)).foregroundStyle(Palette.subdued)
                    }
                case .notDetermined:
                    ProgressView().tint(Palette.text)
                default:
                    VStack(spacing: Space.m) {
                        Icon(name: "camera", size: 36).foregroundStyle(Palette.subdued)
                        Text("Allow camera access in Settings to scan the code.").font(Typo.font(15)).multilineTextAlignment(.center)
                            .foregroundStyle(Palette.subdued)
                        DevicePill(title: "Open Settings", style: .light) {
                            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        }
                    }
                    .padding(Space.xl)
                }
                if d.busy {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black.opacity(0.6))
                    HStack(spacing: Space.s) { ProgressView().tint(Palette.text); Text("Linking…").font(Typo.font(15, .medium)) }
                }
            }
            .frame(width: 280, height: 280)
            if let e = d.error {
                PairingErrorRow(error: e)
                DevicePill(title: "Scan again", style: .outline) { d.error = nil; serial += 1 }
            }
            Spacer(minLength: 0)
            OnboardSecondaryButton(title: "Enter code") { d.go(.enterCode) }
        }
        .task {
            if access == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                access = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("link-scan-step")
    }
}

/// Accent corner brackets over the camera.
private struct ViewfinderCorners: View {
    var body: some View {
        Canvas { ctx, size in
            let l: CGFloat = 34, r: CGFloat = 14
            var p = Path()
            let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, 0, 1, 1), (size.width, 0, -1, 1), (0, size.height, 1, -1),
                                                                   (size.width, size.height, -1, -1)]
            for (x, y, sx, sy) in corners {
                p.move(to: CGPoint(x: x, y: y + sy * l))
                p.addLine(to: CGPoint(x: x, y: y + sy * r))
                p.addQuadCurve(to: CGPoint(x: x + sx * r, y: y), control: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x + sx * l, y: y))
            }
            ctx.stroke(p, with: .color(Palette.accent), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}

/// The camera, reading QR codes (AVFoundation). Calls `onCode` once per appearance.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }
    func updateUIViewController(_ c: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            guard session.canAddOutput(out) else { return }
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
            let s = session
            DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let s = session
            DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  CodeEntry.pairLink(in: text) != nil else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let s = session
            DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
            onCode?(text)
        }
    }
}

private struct LinkedStep: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let d = app.devices
        VStack(spacing: 0) {
            Spacer(minLength: Space.xl)
            ZStack {
                Circle().fill(RadialGradient(colors: [Palette.accent.opacity(0.3), .clear], center: .center, startRadius: 0, endRadius: 120))
                    .frame(width: 240, height: 240)
                Circle().fill(Palette.accent).frame(width: 96, height: 96)
                    .overlay(Icon(name: "check", size: 48).foregroundStyle(.black))
            }
            .frame(height: 180)
            .accessibilityHidden(true)
            OnboardHeader(title: "Linked", line: DeviceSyncText.successBody, center: true)
                .padding(.top, Space.m)
                .accessibilityIdentifier("link-success")
            let names = DeviceSyncText.names(d.status.peers.map(\.name))
            if !names.isEmpty {
                HStack(spacing: Space.s) {
                    DeviceTile(linked: true, size: 32)
                    Text(names).font(Typo.font(15, .bold))
                }
                .padding(.horizontal, Space.l).padding(.vertical, Space.s)
                .background(Capsule().fill(Palette.highlight))
                .padding(.top, Space.xl)
            }
            Spacer(minLength: Space.xl)
            OnboardPrimaryButton(title: "Done") { d.closed() }
                .accessibilityIdentifier("link-done")
        }
    }
}

// MARK: first run and Home

/// The optional screen after the first-run import: link the Mac now, or not.
struct DeviceLinkWelcome: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let d = app.devices
        VStack(spacing: 0) {
            Spacer(minLength: Space.xl)
            DevicesHero(size: 84)
            OnboardHeader(title: DeviceSyncText.welcomeTitle, line: DeviceSyncText.welcomeLine, center: true)
                .padding(.top, Space.l)
            Spacer(minLength: Space.xl)
            Spacer(minLength: 0)
            VStack(spacing: Space.m) {
                OnboardPrimaryButton(title: "Link now") { d.welcomeLink() }
                    .accessibilityIdentifier("link-welcome-now")
                OnboardTextButton(title: "Not now") { d.welcomeOpen = false }
                    .accessibilityIdentifier("link-welcome-skip")
            }
            .padding(.bottom, Space.s)
        }
        .padding(.horizontal, Space.xl)
        .foregroundStyle(Palette.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.base.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("link-welcome")
    }
}

/// Home's one-time nudge (three days in, not linked).
struct DeviceLinkHint: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let d = app.devices
        HStack(spacing: Space.m) {
            DeviceTile(size: 40)
            Text(DeviceSyncText.hint).font(Typo.font(14, .medium)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            DevicePill(title: "Link", style: .accent) { d.dismissHint(); d.open() }
                .accessibilityIdentifier("home-link-hint-link")
            Button { d.dismissHint() } label: {
                Icon(name: "x", size: 16).foregroundStyle(Palette.subdued).frame(width: 28, height: 36).contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("home-link-hint-close")
        }
        .padding(.leading, Space.m).padding(.trailing, Space.xs).padding(.vertical, Space.m)
        .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Palette.highlight))
        .onAppear { d.hintAppeared() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-link-hint")
    }
}
