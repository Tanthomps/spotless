// Downloads on iOS, as far as the system allows (stream ios-polish):
// - The files live in Application Support/Encore/Downloads (the core's downloads dir), which is
//   excluded from iCloud/iTunes backup: they can always be fetched again (Apple's storage rules).
// - The core's own HTTP stack does the fetching. While audio plays the app is never suspended, so
//   downloads simply carry on. Without audio:
//   - iOS 26+: a download the user starts is a `BGContinuedProcessingTask` (the system's progress
//     UI; it keeps the app running in the background until the queue is empty or the user stops it);
//   - otherwise, and as a fallback, `beginBackgroundTask` buys the usual ~30 s after backgrounding.
// - Cellular: the core's NWPathMonitor marks `isExpensive`/`isConstrained` paths metered, and the
//   queue waits there unless Settings › Download using cellular is on (`download_on_metered`).
import BackgroundTasks
import SwiftUI
import UIKit
import os

let downloadLog = Logger(subsystem: "app.spotlessmusic.ios", category: "downloads")

@MainActor
final class DownloadKeeper {
    static let shared = DownloadKeeper()
    /// Continued-processing identifiers: `<prefix>.<uuid>`, permitted by the wildcard in Info.plist.
    nonisolated static let taskPrefix = "app.spotlessmusic.ios.downloads"

    private weak var app: AppModel?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var continuedRunning = false

    /// Tracks still to fetch (queued + in flight).
    var pending: Int {
        guard let d = app?.downloads else { return 0 }
        return d.snapshot.queued + d.active.count
    }

    func attach(_ app: AppModel) {
        self.app = app
        Self.excludeFromBackup()
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in DownloadKeeper.shared.enteredBackground() }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in DownloadKeeper.shared.endBackgroundTask() }
        }
    }

    // MARK: backup

    /// Application Support/Encore/Downloads: not in backups (re-downloadable, possibly gigabytes).
    nonisolated static func excludeFromBackup() {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return }
        var dir = support.appendingPathComponent("Encore/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try dir.setResourceValues(values)
            downloadLog.info("downloads dir excluded from backup: \(dir.path, privacy: .public)")
        } catch {
            downloadLog.error("could not exclude downloads from backup: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: background

    private func enteredBackground() {
        guard pending > 0, bgTask == .invalid, !continuedRunning else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "Spotless downloads") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        downloadLog.info("background: \(self.pending) downloads pending, background task started")
        Task { @MainActor in
            while bgTask != .invalid {
                await app?.downloads.refresh()
                if pending == 0 { downloadLog.info("background: queue finished"); break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            endBackgroundTask()
        }
    }

    func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    /// The user just started a download: on iOS 26+ ask for a continued-processing task so the
    /// queue keeps going if they leave the app. Continued-processing tasks are registered at
    /// submit time, one concrete identifier each, matched by the wildcard in Info.plist.
    func userStartedDownload(title: String) {
        guard #available(iOS 26.0, *), !continuedRunning else { return }
        let id = "\(Self.taskPrefix).\(UUID().uuidString)"
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in DownloadKeeper.shared.run(task) }
        }
        guard ok else { downloadLog.info("continued processing: registration refused"); return }
        let req = BGContinuedProcessingTaskRequest(identifier: id, title: "Downloading", subtitle: title)
        req.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(req)
            continuedRunning = true
            downloadLog.info("continued processing requested for \(title, privacy: .public)")
        } catch {
            downloadLog.info("continued processing unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    @available(iOS 26.0, *)
    private func run(_ task: BGContinuedProcessingTask) {
        var expired = false
        task.expirationHandler = { expired = true }
        Task { @MainActor in
            defer { continuedRunning = false }
            while !expired {
                await app?.downloads.refresh()
                let cols = app?.downloads.snapshot.collections ?? []
                let total = cols.reduce(0) { $0 + $1.total }
                let done = cols.reduce(0) { $0 + $1.done }
                task.progress.totalUnitCount = Int64(max(total, 1))
                task.progress.completedUnitCount = Int64(min(done, total))
                task.updateTitle("Downloading", subtitle: "\(done.formatted()) of \(counted(total, "song"))")
                if pending == 0 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            downloadLog.info("continued processing ended (expired: \(expired))")
            task.setTaskCompleted(success: !expired)
        }
    }
}
