// Device sync on the iPhone (docs/SYNC.md): the status for Settings › Devices and the side menu,
// the linking flow (show a code, enter one, scan one), Bonjour to find a device showing a code
// (`NWBrowser`) and to be found while showing one (`NetService`), the scene-phase hook, the
// first-run welcome and the one-time Home hint. The screens are Screens/Devices.swift.
import Foundation
import Network
import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class DeviceSyncStore {
    enum Step: Equatable { case intro, showCode, enterCode, scan, success }
    /// How a code shown here ended without a link.
    enum CodeEnd: Equatable { case expired, tooManyTries }

    let core: CoreClient
    var status = SyncStatus.unlinked
    /// Linked devices playing something right now (Spotify's "Playing on <device>").
    var remotes: [RemoteDevice] = [] { didSet { sending = [] } }
    /// Devices a command was just sent to; cleared when they answer with a presence (or after 8 s),
    /// so the bar can say "Sending to …" through the sync round's few seconds.
    var sending: Set<String> = []
    /// The one to show: playing first, then the freshest.
    var activeRemote: RemoteDevice? { remotes.first { $0.playing } ?? remotes.first }

    // the linking sheet
    var sheetOpen = false
    var step: Step = .intro
    /// The code shown here (`sync_start_pairing`).
    var shown: SyncPairing?
    var codeEnd: CodeEnd?
    var digits = ""
    var busy = false
    var error: PairingError?
    @ObservationIgnored private var joinTask: Task<Void, Never>?
    /// The join's own 20 s timer ran out (as opposed to the user closing or going back).
    @ObservationIgnored private var joinTimedOut = false
    /// Tests and screenshots: a fixed clock for the countdown.
    var nowOverride: Double?
    /// 200 ms waits for Bonjour to find a device showing a code before joining (tests: 0).
    @ObservationIgnored var discoveryTries = 20

    // first run and Home
    var welcomeOpen = false
    /// The first-run import was offered: the welcome follows it once it closes.
    @ObservationIgnored var welcomePending = false
    var hintDismissed = false
    var hintShownNow = false
    /// Screenshots: show the hint whatever the dates.
    var forceHint = false

    @ObservationIgnored private let prefs: UserDefaults?
    @ObservationIgnored private let firstUse: Double
    @ObservationIgnored private let hintShownBefore: Bool
    @ObservationIgnored private var peersAtStart = 0
    @ObservationIgnored private var pairedAtStart = false
    @ObservationIgnored private var sawCode = false
    @ObservationIgnored private let bonjour = SyncBonjour()
    @ObservationIgnored private let advertiser = SyncAdvertiser()

    private enum K { static let firstUse = "sync_first_use", hintShown = "sync_hint_shown", welcomeShown = "sync_welcome_shown" }

    init(core: CoreClient, prefs: UserDefaults?) {
        self.core = core
        self.prefs = prefs
        let now = Date().timeIntervalSince1970
        if let t = prefs?.object(forKey: K.firstUse) as? Double { firstUse = t } else {
            firstUse = now
            prefs?.set(now, forKey: K.firstUse)
        }
        hintShownBefore = prefs?.bool(forKey: K.hintShown) ?? false
    }

    var now: Double { nowOverride ?? Date().timeIntervalSince1970 }
    var paired: Bool { status.paired }

    func refresh() async {
        if let s = try? await core.syncStatus() { apply(s) }
    }

    /// The app came to the front or went behind (scene phase): sync speeds up or slows down.
    func setActive(_ active: Bool) {
        Task {
            if let s = try? await core.syncSetActive(active) { apply(s) }
            if active { refreshRemotes() }
        }
    }

    /// Every status from the core (`sync-changed` and command answers).
    func refreshRemotes() {
        guard status.paired else { remotes = []; return }
        Task { if let r = try? await core.presenceList() { remotes = r } }
    }

    /// play / pause / next / prev on another device; shown at once, confirmed by its next presence.
    func control(_ d: RemoteDevice, _ cmd: String) {
        if let i = remotes.firstIndex(where: { $0.dev == d.dev }), cmd == "play" || cmd == "pause" {
            var r = remotes; r[i].playing = cmd == "play"
            remotes = r // (clears `sending`; it's set again right below)
        }
        Haptics.selection()
        sending.insert(d.dev)
        Task {
            try? await core.presenceSend(dev: d.dev, cmd: cmd)
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            sending.remove(d.dev)
        }
    }

    func apply(_ s: SyncStatus) {
        let wasPaired = status.paired
        status = s
        if s.paired != wasPaired { refreshRemotes() }
        guard step == .showCode, let shown, codeEnd == nil else { return }
        if s.pairing?.code == shown.code { sawCode = true; return }
        guard sawCode, s.pairing == nil else { return }
        if s.peers.count > peersAtStart || (s.paired && !pairedAtStart) {
            linked()
        } else {
            codeEnd = now < shown.expiresAt - 1 ? .tooManyTries : .expired
            advertiser.stop()
        }
    }

    // MARK: Settings › Devices

    /// `fail` gets the sentence to show when the core refuses (the card keeps its state).
    func syncNow(fail: @escaping @MainActor (String) -> Void) {
        Task {
            do { apply(try await core.syncNow()) } catch {
                fail(friendlyError(error, "Couldn't sync. Check that both devices are on the same Wi-Fi."))
            }
        }
    }

    func unlink(done: @escaping @MainActor () -> Void, fail: @escaping @MainActor (String) -> Void) {
        Task {
            do { apply(try await core.syncUnpair()); done() } catch {
                fail(friendlyError(error, "Couldn't unlink. Try again."))
            }
        }
    }

    // MARK: the linking sheet

    func open(_ step: Step = .intro) {
        reset()
        self.step = step
        sheetOpen = true
        if step == .showCode { showCode() }
        if step == .enterCode || step == .scan { bonjour.start() }
    }

    /// `spotless://pair?…` (the system camera or a pasted link): join with it straight away.
    func openJoin(qr: String) {
        open(.enterCode)
        let r = CodeEntry.read(qr)
        digits = r.digits
        join(qr: r.qr ?? qr)
    }

    func go(_ s: Step) {
        error = nil
        joinTask?.cancel(); joinTask = nil
        if step == .showCode && s != .showCode { cancelCode() }
        withAnimation(Motion.spring) { step = s }
        switch s {
        case .showCode: showCode()
        case .enterCode, .scan: bonjour.start()
        default: break
        }
    }

    /// The sheet went away (Done, Cancel or a swipe).
    func closed() {
        joinTask?.cancel(); joinTask = nil
        if step == .showCode && codeEnd == nil { cancelCode() }
        bonjour.stop()
        advertiser.stop()
        sheetOpen = false
    }

    private func reset() {
        step = .intro; shown = nil; codeEnd = nil; digits = ""; busy = false; error = nil; sawCode = false
    }

    func showCode() {
        shown = nil; codeEnd = nil; error = nil; sawCode = false
        peersAtStart = status.peers.count
        pairedAtStart = status.paired
        busy = true
        // ponytail: 20 s for the core to open the pairing port; a slower answer is ignored (and cancelled).
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, self.step == .showCode, self.shown == nil, self.busy else { return }
            self.busy = false
            self.error = PairingError.from("unreachable")
            Haptics.error()
        }
        Task {
            defer { busy = false; timeout.cancel() }
            do {
                let p = try await core.syncStartPairing()
                guard step == .showCode, error == nil else { _ = try? await core.syncCancelPairing(); return }
                shown = p.pairing
                advertiser.start(dev: status.deviceId.isEmpty ? UUID().uuidString : status.deviceId, port: p.port)
                // The status that carries this code (events may have raced the answer).
                if let s = try? await core.syncStatus() { apply(s) }
            } catch {
                self.error = PairingError.from(FriendlyError.raw(error))
            }
        }
    }

    /// The code shown here ran out (the countdown reached zero).
    func codeExpired() {
        guard step == .showCode, codeEnd == nil else { return }
        codeEnd = .expired
        advertiser.stop()
    }

    private func cancelCode() {
        advertiser.stop()
        shown = nil
        Task { if let s = try? await core.syncCancelPairing() { status = s } }
    }

    /// Typed or pasted into the boxes: a whole link joins with it; six digits join.
    func typed(_ raw: String) {
        let r = CodeEntry.read(raw)
        if error != nil, r.digits != digits { error = nil }
        digits = r.digits
        if let qr = r.qr { join(qr: qr) } else if digits.count == 6 { join() }
    }

    /// Join the device showing `digits` (or the one in `qr`). Each try costs the code one of its
    /// three, so devices that can't be reached are skipped, never retried with the same code.
    func join(qr: String? = nil) {
        guard !busy else { return }
        if qr == nil && digits.count != 6 { error = PairingError.from("bad_code"); return }
        busy = true; error = nil
        bonjour.start()
        joinTask?.cancel()
        joinTimedOut = false
        joinTask = Task {
            defer { busy = false }
            // ponytail: 20 s for the whole join; per-host timeouts if one dead host eats it all.
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                self.joinTimedOut = true
                self.joinTask?.cancel()
                self.busy = false
                self.error = PairingError.from("unreachable")
                Haptics.error()
            }
            defer { timeout.cancel() }
            var hosts: [SyncBonjour.Host] = []
            if qr == nil {
                // A device showing a code advertises it: give Bonjour a moment to find it.
                for _ in 0..<discoveryTries where bonjour.hosts.isEmpty && !bonjour.denied {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                hosts = bonjour.hosts.filter { $0.dev != status.deviceId }
            }
            var last: PairingError?
            for host in hosts.isEmpty ? [nil] : hosts.map(Optional.some) {
                do {
                    let s = try await core.syncJoin(code: qr == nil ? digits : nil, qr: qr, host: host?.host, port: host?.port)
                    // Closed, went back or timed out meanwhile: don't jump to Linked behind the user's back.
                    guard !Task.isCancelled else { return }
                    apply(s)
                    linked()
                    return
                } catch {
                    if Task.isCancelled { return }
                    let e = PairingError.from(FriendlyError.raw(error))
                    last = e
                    if e.kind != .unreachable { break }
                }
            }
            if let e = last, e.kind == .unreachable || e.kind == .other, bonjour.denied {
                last = .localNetwork
            }
            if Task.isCancelled { return }
            error = last
            if last?.kind != .unreachable && last?.kind != .localNetwork && last?.kind != .other { digits = "" }
            Haptics.error()
        }
    }

    private func linked() {
        advertiser.stop()
        bonjour.stop()
        busy = false
        error = nil
        withAnimation(Motion.spring) { step = .success }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { await refresh() }
    }

    // MARK: first run and Home

    /// The first-run import closed: offer linking once, if this phone isn't linked.
    func importClosed() {
        guard welcomePending else { return }
        welcomePending = false
        guard !paired, prefs?.bool(forKey: K.welcomeShown) != true else { return }
        prefs?.set(true, forKey: K.welcomeShown)
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            welcomeOpen = true
        }
    }

    func welcomeLink() {
        welcomeOpen = false
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            open()
        }
    }

    /// Home's one-time hint: three days after first use, not linked, shown once (it stays for the
    /// session it first appeared in, until closed).
    var showsHint: Bool {
        guard !paired, !hintDismissed else { return false }
        if forceHint || hintShownNow { return true }
        return !hintShownBefore && prefs != nil && now - firstUse >= 3 * 86400
    }

    func hintAppeared() {
        guard !hintShownNow, prefs != nil, !forceHint else { return }
        hintShownNow = true
        prefs?.set(true, forKey: K.hintShown)
    }

    func dismissHint() { withAnimation(Motion.quick) { hintDismissed = true } }
}

// MARK: Bonjour

/// Finds devices showing a code (`_spotless-sync._tcp` with TXT `pairing=1`) and resolves each to
/// an IPv4 address and port for `sync_join`. Notices when Local Network access is denied.
@MainActor
final class SyncBonjour {
    struct Host: Equatable { var host: String; var port: Int; var dev: String? }
    static let type = "_spotless-sync._tcp"

    private(set) var hosts: [Host] = []
    private(set) var denied = false
    private var browser: NWBrowser?
    private var resolving: [NWEndpoint: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.type, domain: nil), using: params)
        b.stateUpdateHandler = { [weak self] state in Task { @MainActor in self?.update(state) } }
        b.browseResultsChangedHandler = { [weak self] results, _ in Task { @MainActor in self?.update(results) } }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
        hosts = []
    }

    private func update(_ state: NWBrowser.State) {
        switch state {
        case .waiting(let e), .failed(let e): if Self.isPolicyDenied(e) { denied = true }
        case .ready: denied = false
        default: break
        }
    }

    nonisolated static func isPolicyDenied(_ e: NWError) -> Bool {
        // kDNSServiceErr_PolicyDenied: Local Network access was refused in Settings.
        if case .dns(let code) = e, code == -65570 { return true }
        return false
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        for r in results {
            guard case .bonjour(let txt) = r.metadata, txt["pairing"] == "1" else { continue }
            resolve(r.endpoint, dev: txt["dev"])
        }
    }

    /// Connect once to learn the address (the core's server ignores a connection that says nothing).
    private func resolve(_ endpoint: NWEndpoint, dev: String?) {
        guard resolving[endpoint] == nil else { return }
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let c = NWConnection(to: endpoint, using: params)
        resolving[endpoint] = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let c else { return }
            switch state {
            case .ready:
                if case .hostPort(let h, let p)? = c.currentPath?.remoteEndpoint {
                    let host = Self.string(h)
                    Task { @MainActor in self?.found(Host(host: host, port: Int(p.rawValue), dev: dev)) }
                }
                c.cancel()
            case .failed(let e), .waiting(let e):
                if Self.isPolicyDenied(e) { Task { @MainActor in self?.denied = true } }
                c.cancel()
            default: break
            }
        }
        c.start(queue: .main)
    }

    private func found(_ h: Host) {
        if !hosts.contains(h) { hosts.append(h) }
    }

    nonisolated static func string(_ h: NWEndpoint.Host) -> String {
        switch h {
        case .ipv4(let a): return "\(a)".components(separatedBy: "%")[0]
        case .ipv6(let a): return "\(a)".components(separatedBy: "%")[0]
        case .name(let n, _): return n
        @unknown default: return "\(h)"
        }
    }
}

/// While this phone shows a code, it says so on the network, so a Mac typing the code finds it
/// (the core's mDNS looks for `pairing=1`; iOS can't do raw multicast, so Bonjour does it here).
@MainActor
final class SyncAdvertiser {
    private var service: NetService?

    func start(dev: String, port: Int) {
        stop()
        let s = NetService(domain: "local.", type: "\(SyncBonjour.type).", name: dev, port: Int32(port))
        s.setTXTRecord(NetService.data(fromTXTRecord: ["dev": Data(dev.utf8), "v": Data("1".utf8), "pairing": Data("1".utf8)]))
        s.publish()
        service = s
    }

    func stop() {
        service?.stop()
        service = nil
    }
}
