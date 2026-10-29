import SwiftUI
import UIKit
import UserNotifications

@main
struct DroprrPhoneApp: App {
    @State private var model = PhoneModel()

    init() {
        CrashLog.install()
        CrashLog.cleanTemporaryFiles()
    }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .tint(Look.accentText)
                // Scanning the pairing QR code with the Camera app opens droprr://pair?…
                .onOpenURL { url in model.pair(with: url.absoluteString, confirm: true) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Desktops queue items for a phone, so collect them each time the app comes forward. While the
            // app is open it also listens and advertises on the Wi-Fi, so computers can send directly.
            if phase == .active {
                model.startLocalNetwork()
                Task { await model.collectInbox() }
            } else if phase == .background {
                model.enterBackground()
            }
        }
    }
}

@Observable
@MainActor
final class PhoneModel {
    let settings = DroprrSettings.shared
    var history: [HistoryEntry] = []
    var lastSendResult: String?
    var progress: Double?
    var sending = false
    var collecting = false
    var lastCollect: String?

    /// Visible in the Files app under On My iPhone › Droprr.
    nonisolated static var inbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Received")
    }

    private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("history.json")
    }

    static let historyLimit = 30

    /// HTTPS only, and only while the app is open (protocol 2): iOS doesn't let apps listen in the background.
    @ObservationIgnored private var receiver: DroprrReceiver?
    /// A computer asking to pair over the Wi-Fi, waiting for the person to confirm.
    var pairQuestion: LANPairRequest?
    @ObservationIgnored private var pairAnswer: CheckedContinuation<Bool, Never>?

    init() {
        if let data = try? Data(contentsOf: Self.historyURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = saved.filter(\.isAvailable)
        }
    }

    // MARK: Local network (protocol 2)

    func startLocalNetwork() {
        guard settings.localNetwork else { return stopLocalNetwork() }
        LANDiscovery.shared.start()
        if receiver == nil {
            let receiver = DroprrReceiver(settings: settings, inbox: Self.inbox)
            receiver.onItem = { [weak self] item in self?.record(item, from: nil) }
            receiver.onPair = { [weak self] in self?.paired($0) }
            receiver.onPairRequest = { [weak self] request in await self?.ask(request) ?? false }
            self.receiver = receiver
        }
        receiver?.startSecure()
        #if DEBUG
        // Tests: DROPRR_JOIN=<one code link> pairs with it as if scanned.
        if let code = ProcessInfo.processInfo.environment["DROPRR_JOIN"] {
            Task {
                try? await Task.sleep(for: .seconds(2))
                pair(with: code)
                while case .working = pairingStatus { try? await Task.sleep(for: .milliseconds(200)) }
                NSLog("Droprr test: join %@", String(describing: pairingStatus))
            }
        }
        // Tests: DROPRR_AUTO_LAN_PAIR=<name> pairs with that nearby device once it's found.
        if let name = ProcessInfo.processInfo.environment["DROPRR_AUTO_LAN_PAIR"] {
            Task {
                try? await Task.sleep(for: .seconds(4))
                guard let device = LANDiscovery.shared.nearby.first(where: { $0.name == name }) else { return NSLog("Droprr test: %@ not found", name) }
                do {
                    let peer = try await LANPairing.pair(with: device) { NSLog("Droprr test: code %@", $0) }
                    NSLog("Droprr test: paired %@ lan=%@", peer.name, peer.lan?.joined(separator: ",") ?? "")
                    await collectInbox()
                    NSLog("Droprr test: collect %@", lastCollect ?? "")
                } catch {
                    NSLog("Droprr test: pairing failed %@", error.localizedDescription)
                }
            }
        }
        #endif
    }

    func stopLocalNetwork() {
        receiver?.stop()
        LANDiscovery.shared.stop()
    }

    /// Going to the background: keep listening a little longer so a transfer in progress can finish.
    func enterBackground() {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Droprr receive") { [weak self] in
            self?.stopLocalNetwork()
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            if UIApplication.shared.applicationState == .background { stopLocalNetwork() }
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            task = .invalid
        }
    }

    /// Runs `work` with background time, so leaving the app doesn't cut a send or collection short.
    func withBackgroundTime<T>(_ name: String, _ work: () async -> T) async -> T {
        // When the time runs out, cancel the send (the expiration handler must end the task, or iOS kills the app).
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.sendTask?.cancel()
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        return await work()
    }

    /// Shows the "Pair with …?" question and waits for Pair or Decline.
    private func ask(_ request: LANPairRequest) async -> Bool {
        pairAnswer?.resume(returning: false)
        pairQuestion = request
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        // The computer gives up after 60 seconds; so does the question.
        Task {
            try? await Task.sleep(for: .seconds(60))
            if pairQuestion?.code == request.code { answerPairQuestion(false) }
        }
        return await withCheckedContinuation { pairAnswer = $0 }
    }

    func answerPairQuestion(_ accept: Bool) {
        pairQuestion = nil
        pairAnswer?.resume(returning: accept)
        pairAnswer = nil
    }

    /// A computer paired with this phone over the Wi-Fi: add or update it with both tokens and its pin.
    private func paired(_ request: PairRequest) {
        // Same rules as the Mac: a device token updates only its own peer; LAN pairing adds a new entry.
        let match: Int?
        if let existing = request.existingPeerID {
            match = settings.peers.firstIndex { $0.id == existing }
        } else if request.viaLAN {
            match = nil
        } else {
            match = request.deviceID.flatMap { id in settings.peers.firstIndex { $0.deviceID == id } }
                ?? settings.peers.firstIndex { $0.matches(deviceName: request.name) }
        }
        let peerID: UUID
        if let i = match {
            settings.peers[i].platform = request.platform
            settings.peers[i].remoteName = request.name
            if settings.peers[i].host.isEmpty { settings.peers[i].host = request.host }
            if let token = request.token { settings.peers[i].token = token }
            settings.peers[i].acceptToken = request.acceptToken
            peerID = settings.peers[i].id
        } else {
            let peer = Peer(name: settings.uniqueName(request.name), host: request.host, port: request.port, platform: request.platform,
                            remoteName: request.name, token: request.token, acceptToken: request.acceptToken)
            settings.peers.append(peer)
            peerID = peer.id
        }
        settings.learn(peerID, deviceID: request.deviceID, fingerprint: request.fingerprint, tlsPort: request.tlsPort,
                       lan: request.lan, replacePin: request.existingPeerID == nil && request.fingerprint != nil)
        pairingStatus = .success("Paired with \(request.name)")
    }

    /// A computer paired before protocol 2 doesn't have a token for this phone yet. Once it answers /ping
    /// with protocol 2, give it one (POST /pair with this phone's current token), so it can send directly.
    private func upgradePairing(_ peer: Peer, client: DroprrClient) async {
        guard (peer.acceptToken ?? "").isEmpty, let ping = try? await client.ping(), (ping.proto ?? 1) >= 2 else { return }
        let minted = DroprrSettings.generateToken()
        guard let result = try? await client.pair(name: settings.deviceName, platform: DroprrSettings.platform, token: minted),
              let i = settings.peers.firstIndex(where: { $0.id == peer.id }) else { return }
        settings.peers[i].acceptToken = minted
        if let token = result.token { settings.peers[i].token = token }
        settings.learn(peer.id, deviceID: result.deviceID ?? ping.id, fingerprint: result.fingerprint ?? ping.fp,
                       tlsPort: result.tlsPort ?? ping.tlsPort, lan: result.lan, host: result.host,
                       replacePin: client.path == .tailscale)
    }

    /// Inbox items saved here whose DELETE didn't go through yet (kept across launches).
    private var acknowledgedLocally: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "acknowledgedLocally") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: "acknowledgedLocally") }
    }

    var newItems: [HistoryEntry] { history.filter(\.isNew) }
    var seenItems: [HistoryEntry] { history.filter { !$0.isNew } }

    private func record(_ item: ReceivedItem, from source: String?) {
        // Auto-copy skips big files, which would be read whole on the main thread.
        if settings.autoCopy {
            if case .file(let url) = item.kind, ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 20 << 20 {
            } else {
                Clipboard.copy(item)
            }
        }
        Motion.perform {
            history.insert(HistoryEntry(item, source: source), at: 0)
            trimAndSave()
        }
        // No notification here: items only arrive while the app is open, and the New list shows them.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// Tapping an item: copy text and links, then move it out of New and clear its notification.
    func use(_ entry: HistoryEntry) {
        switch entry.item.kind {
        case .text(let text): Clipboard.copy(text: text)
        case .url(let url): Clipboard.copy(url: url)
        case .file: break
        }
        markSeen(entry)
    }

    func markSeen(_ entry: HistoryEntry) {
        guard let i = history.firstIndex(where: { $0.id == entry.id }), history[i].isNew else { return }
        Motion.perform { history[i].isNew = false }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [entry.id.uuidString])
        trimAndSave()
    }

    func markAllSeen() {
        let ids = newItems.map(\.id.uuidString)
        Motion.perform { for i in history.indices { history[i].isNew = false } }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        trimAndSave()
    }

    func delete(_ entry: HistoryEntry) {
        Motion.perform { history.removeAll { $0.id == entry.id } }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [entry.id.uuidString])
        trimAndSave()
    }

    func clearHistory() {
        Motion.perform { history.removeAll { !$0.isNew } }
        trimAndSave()
    }

    /// Keeps every new item plus the most recent seen ones. Received files stay in the Files app.
    private func trimAndSave() {
        var seen = 0
        history = history.filter { entry in
            if entry.isNew { return true }
            seen += 1
            return seen <= Self.historyLimit
        }
        try? FileManager.default.createDirectory(at: Self.historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: Self.historyURL, options: .atomic) }
    }

    // MARK: Pairing

    enum PairingStatus: Equatable {
        case working(String)
        case success(String)
        case failure(String)
    }

    /// Shown as a card over the app while and after a QR code is scanned.
    var pairingStatus: PairingStatus?

    /// A pairing link opened from outside the app (Camera, Safari, Messages), waiting for the user to confirm.
    var pendingPairing: PairingInfo?

    /// Peer that a pairing code would replace, if any.
    /// The peer a pairing code would replace: the same rule `DroprrSettings.apply` uses (id, address, name).
    func existingPeer(for info: PairingInfo) -> Peer? {
        let addresses = [info.host, info.dns].compactMap { $0 }.filter { !$0.isEmpty }
        return settings.peers.first { peer in
            (info.id != nil && peer.deviceID == info.id)
                || addresses.contains { peer.host.caseInsensitiveCompare($0) == .orderedSame } || peer.matches(deviceName: info.name)
        }
    }

    /// Handles a scanned or opened pairing code. Links opened from outside the app are never applied
    /// directly: they wait in `pendingPairing` until the user taps Pair.
    func pair(with code: String, confirm: Bool = false) {
        let info: PairingInfo
        switch PairingInfo.parse(code) {
        case .success(let parsed): info = parsed
        case .failure(.newerVersion):
            pairingStatus = .failure("This pairing code is from a newer version of Droprr. Update the app on this iPhone and try again.")
            return
        case .failure:
            pairingStatus = .failure("That isn't a Droprr pairing code.")
            return
        }
        guard info.pointsInsideTailnet else {
            pairingStatus = .failure("This code points outside your Tailscale or home network, so Droprr won't use it.")
            return
        }
        if confirm {
            pendingPairing = info
        } else {
            completePairing(info)
        }
    }

    func completePairing(_ info: PairingInfo) {
        pendingPairing = nil
        if let secret = info.join { return join(info, secret: secret) }
        var peer = settings.apply(info)
        pairingStatus = .working("Pairing with \(peer.name)")
        Task {
            do {
                // Pair both ways with the QR code's token; the desktop answers with a device token
                // just for this phone, which replaces the QR token from now on.
                // Protocol 2: this phone also mints a token for the desktop, for direct sends while it's open.
                let minted = DroprrSettings.generateToken()
                let client = try await DroprrClient.connect(peer).client
                let result = try await client.pair(name: settings.deviceName, platform: DroprrSettings.platform, token: minted)
                if let i = settings.peers.firstIndex(where: { $0.id == peer.id }) {
                    if let token = result.token { settings.peers[i].token = token }
                    settings.peers[i].acceptToken = minted
                    peer = settings.peers[i]
                }
                settings.learn(peer.id, deviceID: result.deviceID, fingerprint: result.fingerprint, tlsPort: result.tlsPort,
                               lan: result.lan, host: result.host, replacePin: result.fingerprint != nil)
                peer = settings.peers.first { $0.id == peer.id } ?? peer
                let ping = try await DroprrClient.connect(peer).client.ping()
                if let i = settings.peers.firstIndex(where: { $0.id == peer.id }) {
                    settings.peers[i].platform = ping.platform
                    settings.peers[i].remoteName = ping.name
                }
                pairingStatus = .success("Paired with \(ping.name)")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    if case .success = pairingStatus { pairingStatus = nil }
                }
                await collectInbox()
            } catch {
                pairingStatus = .failure("Added \(peer.name), but it didn't answer: \(error.localizedDescription) Check that both devices are on the same Wi-Fi or on Tailscale.")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    /// The device that was just added, for the Send tab to show and select.
    var justAdded: UUID?

    /// A computer was added from the one code: no separate screen; the Send tab selects it and shows its usual
    /// success line, "<name> added".
    private func added(_ id: UUID) {
        pairingStatus = nil
        guard let peer = settings.peers.first(where: { $0.id == id }) else { return }
        settings.lastPeerID = id
        justAdded = id
        lastSendResult = "\(peer.name) added"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// The one code: pair with the computer's join secret (no token in the code). Nothing is saved until the computer
    /// answers with this phone's device token.
    private func join(_ info: PairingInfo, secret: String) {
        pairingStatus = .working("Pairing with \(info.name)")
        Task {
            do {
                let minted = DroprrSettings.generateToken()
                let result = try await DroprrClient.join(info.peer, secret: secret, name: settings.deviceName,
                                                         platform: DroprrSettings.platform, token: minted)
                guard let token = result.token else { throw DroprrError.notPaired }
                var paired = info
                paired.token = token
                paired.join = nil
                var peer = settings.apply(paired)
                if let i = settings.peers.firstIndex(where: { $0.id == peer.id }) {
                    settings.peers[i].acceptToken = minted
                    peer = settings.peers[i]
                }
                settings.learn(peer.id, deviceID: result.deviceID, fingerprint: result.fingerprint, tlsPort: result.tlsPort,
                               lan: result.lan, host: result.host, replacePin: result.fingerprint != nil)
                added(peer.id)
                await collectInbox()
            } catch DroprrError.server(409, let message) {
                // Already paired with each other: nothing to do, so it's a success like any pairing.
                if let known = settings.peers.first(where: { peer in
                    (info.id != nil && peer.deviceID == info.id) || (info.fp != nil && peer.fingerprint == info.fp)
                }), known.token?.isEmpty == false {
                    added(known.id)
                    return
                }
                pairingStatus = .failure("\(info.name) says this iPhone is \(message).")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            } catch DroprrError.server(401, _) {
                pairingStatus = .failure("That code has expired. Open Pair a phone on \(info.name) again and scan the new code.")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            } catch {
                pairingStatus = .failure("Couldn't reach \(info.name): \(error.localizedDescription) Check that both devices are on the same Wi-Fi or on Tailscale.")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    // MARK: Inbox

    /// Pulls items each desktop is holding for this phone (GET /inbox), then acknowledges them.
    func collectInbox() async {
        await withBackgroundTime("Droprr collect") { await collectInboxNow() }
    }

    private func collectInboxNow() async {
        let desktops = settings.peers.filter { !$0.isPhone }
        guard !collecting, !desktops.isEmpty else { return }
        collecting = true
        defer { collecting = false }
        var count = 0
        var reached = 0
        var problems: [String] = []
        for peer in desktops {
            let client: DroprrClient
            do {
                client = try await DroprrClient.connect(peer).client
            } catch DroprrError.identityChanged(let name) {
                problems.append("\(name)'s identity changed. Pair again.")
                continue
            } catch {
                continue
            }
            guard let items = try? await client.inbox(for: settings.deviceName) else { continue }
            reached += 1
            // Pairings from before protocol 2: learn the computer's id (and pin it over Tailscale), which
            // also merges a computer paired both ways into one entry.
            if peer.deviceID == nil || peer.fingerprint == nil { _ = await settings.ping(peer) }
            await upgradePairing(peer, client: client)
            for entry in items {
                // Already saved last time; only its acknowledgement failed. Don't save it twice.
                if acknowledgedLocally.contains(entry.id) {
                    if (try? await client.acknowledge(entry)) != nil { acknowledgedLocally.remove(entry.id) }
                    continue
                }
                do {
                    let item: ReceivedItem
                    switch entry.type {
                    case "file":
                        let temp = try await client.download(entry)
                        let dest = Self.uniqueDestination(for: entry.name)
                        try FileManager.default.moveItem(at: temp, to: dest)
                        item = ReceivedItem(kind: .file(dest))
                    case "url":
                        // Only http(s) is a link; anything else is kept as text.
                        if let url = URL(string: entry.content ?? ""), Links.isWeb(url) {
                            item = ReceivedItem(kind: .url(url))
                        } else {
                            item = ReceivedItem(kind: .text(entry.content ?? ""))
                        }
                    default:
                        item = ReceivedItem(kind: .text(entry.content ?? ""))
                    }
                    // Saved: show it, then acknowledge. If that fails, remember it so it isn't saved again.
                    record(item, from: peer.name)
                    count += 1
                    if (try? await client.acknowledge(entry)) == nil { acknowledgedLocally.insert(entry.id) }
                } catch {
                    continue   // left in the outbox; we'll try again next time
                }
            }
        }
        if let problem = problems.first {
            lastCollect = problem
        } else if reached == 0 {
            lastCollect = settings.localNetwork
                ? "Couldn't reach your computers. Are you on the same Wi-Fi, or on Tailscale?"
                : "Couldn't reach your computers over Tailscale. Local network is off in Settings."
        } else {
            lastCollect = count == 0 ? "Up to date" : "Collected \(count) item\(count == 1 ? "" : "s")"
        }
    }

    private static func uniqueDestination(for rawName: String) -> URL {
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var name = (rawName as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
        while name.hasPrefix(".") { name.removeFirst() }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = inbox.appendingPathComponent(name.isEmpty ? "Droprr item" : name)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = inbox.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: Sending

    /// Sends everything staged on the Send tab, in order. Returns true if all of it arrived.
    @discardableResult
    func send(_ payloads: [SendPayload], to peer: Peer) async -> Bool {
        guard !payloads.isEmpty else { return false }
        settings.lastPeerID = peer.id
        sending = true
        progress = nil
        defer { sending = false; progress = nil; sendTask = nil }
        let label = payloads.map(\.label).joined(separator: ", ")
        lastSendResult = "Sending \(label) to \(peer.name)…"
        let work = Task { @MainActor () -> Bool in
            do {
                let (client, identityChanged) = try await DroprrClient.connect(peer)
                for payload in payloads {
                    try Task.checkCancellation()
                    try await payload.send(with: client) { [weak self] in self?.progress = $0 }
                }
                if let i = settings.peers.firstIndex(where: { $0.id == peer.id }) { settings.peers[i].lastPath = client.path.rawValue }
                lastSendResult = identityChanged
                    ? "Sent \(label) to \(peer.name) (Tailscale). \(peer.name)'s identity changed. Pair again."
                    : "Sent \(label) to \(peer.name) (\(client.path.label))."
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                return true
            } catch {
                if Task.isCancelled {
                    lastSendResult = "Canceled sending to \(peer.name)."
                } else {
                    lastSendResult = "Couldn't send to \(peer.name): \(error.localizedDescription)"
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
                return false
            }
        }
        sendTask = work
        return await withBackgroundTime("Droprr send") { await work.value }
    }

    @ObservationIgnored private var sendTask: Task<Bool, Never>?

    /// Stops the send in progress (Cancel on the status line).
    func cancelSend() {
        sendTask?.cancel()
    }

    /// Whatever is on the clipboard right now, or nil if it's empty.
    func clipboardPayload() -> SendPayload? {
        let pb = UIPasteboard.general
        if let url = pb.url, !url.isFileURL { return .url(url) }
        if let text = pb.string { return .text(text) }
        if let image = pb.image, let png = image.pngData() {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard.png")
            try? png.write(to: file)
            return .files([file])
        }
        return nil
    }
}

/// One received item in the Received tab. Files are stored by name, since the app's
/// container path changes between installs.
struct HistoryEntry: Codable, Identifiable {
    var id: UUID
    var date: Date
    var source: String?
    var isNew: Bool
    var type: String      // file, text, url
    var value: String     // file name, text, or link

    init(_ item: ReceivedItem, source: String?) {
        id = item.id
        date = item.date
        self.source = source
        isNew = true
        switch item.kind {
        case .file(let url): type = "file"; value = url.lastPathComponent
        case .text(let text): type = "text"; value = text
        case .url(let url): type = "url"; value = url.absoluteString
        }
    }

    var item: ReceivedItem {
        let kind: ReceivedItem.Kind
        switch type {
        case "file": kind = .file(PhoneModel.inbox.appendingPathComponent(value))
        case "url": kind = URL(string: value).flatMap { Links.isWeb($0) ? .url($0) : nil } ?? .text(value)
        default: kind = .text(value)
        }
        return ReceivedItem(id: id, kind: kind, date: date)
    }

    /// Files deleted in the Files app drop out of the list.
    var isAvailable: Bool {
        type != "file" || FileManager.default.fileExists(atPath: PhoneModel.inbox.appendingPathComponent(value).path)
    }
}
