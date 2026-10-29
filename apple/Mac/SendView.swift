import SwiftUI
import UniformTypeIdentifiers

/// The Send window: pick a device, add files and/or text, then Send (⌘↩).
/// Dropping files straight onto a device card still sends them right away.
struct SendView: View {
    @Bindable var model: MacModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var selectedID: UUID?
    @State private var files: [URL] = []
    @State private var text = ""
    @State private var dropTargeted = false
    @FocusState private var typing: Bool

    private var selected: Peer? {
        model.settings.peers.first { $0.id == selectedID } ?? model.settings.lastPeer
    }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasContent: Bool { !files.isEmpty || !trimmed.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.isAtelier ? Space.xl : Space.lg) {
            header

            if model.settings.peers.isEmpty {
                emptyState
            } else {
                devices
                dropArea
                composer
                SendStatusView(message: model.lastSendResult, progress: model.progress, onCancel: model.cancelSend)
                bottomBar
            }
        }
        .padding(.horizontal, Look.isAtelier ? 36 : 28)
        .padding(.top, Space.lg)
        .padding(.bottom, 28)
        .frame(width: 600)
        .seamlessWindow()
        .lookRoot()
        .motion(Motion.standard, value: model.lastSendResult)
        .motion(Motion.fast, value: files)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if Look.isAtelier {
                HStack(alignment: .bottom, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: 6) {
                        Kicker("Droprr")
                        Text("Send").font(Look.display(40))
                    }
                    Spacer()
                    LogoBadge(size: 40).padding(.bottom, 6)
                }
            } else {
                HStack(spacing: Space.md) {
                    LogoBadge(size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send").font(Look.display(32))
                        Text(selected.map { "To \($0.name)" } ?? "Choose a device")
                            .font(.system(size: 13)).foregroundStyle(Look.muted)
                    }
                    Spacer()
                }
            }
            Hairline()
        }
        // The gear floats in the top-right corner without changing the header's layout.
        .overlay(alignment: .topTrailing) {
            Button {
                openSettings()
                bringToFront()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(HoverButtonStyle(.plain))
            .foregroundStyle(Look.muted)
            .accessibilityLabel("Settings")
            .hoverHint("Settings (⌘,)")
            .keyboardShortcut(",")
            .offset(y: -22)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("No devices yet").font(Look.display(24))
            Text("Pair your iPhone or add your PC in Settings to start sending.")
                .foregroundStyle(Look.muted)
            Button("Open Settings") {
                openSettings()
                bringToFront()
            }
            .buttonStyle(PrimaryStyle())
            .keyboardShortcut(",")
            .padding(.top, Space.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.lg)
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Kicker("Send to")
            // Atelier tabs scroll sideways when there are many; cards wrap onto more rows (at most 4 per row).
            let layout = Look.isAtelier
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 28))
                : AnyLayout(GridFlowLayout(columns: min(model.settings.peers.count + 1, 4), spacing: Space.md))
            ScrollView(Look.isAtelier ? .horizontal : [], showsIndicators: false) {
            layout {
                ForEach(Array(model.settings.peers.enumerated()), id: \.element.id) { index, peer in
                    DeviceTab(peer: peer, selected: peer.id == selected?.id,
                              waiting: model.waiting(for: peer),
                              onSelect: { selectedID = peer.id },
                              onDropFiles: { urls in Task { await model.send(.files(urls), to: peer) } },
                              onClearWaiting: { model.clearWaiting(for: peer) },
                              onMissingToken: { fixToken(peer) })
                        // ⌘1…⌘9 pick a device.
                        .background {
                            if index < 9 {
                                Button("") { selectedID = peer.id }
                                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                                    .hidden()
                            }
                        }
                }
                // Add a device: opens Pair a phone (the one code). Never a send target.
                AddDeviceTile {
                    openWindow(id: "pair")
                    bringToFront()
                }
            }
            }
            .scrollDisabled(!Look.isAtelier)
        }
    }

    private var dropArea: some View {
        VStack(spacing: Space.md) {
            if files.isEmpty {
                if Look.isAtelier {
                    Image(systemName: dropTargeted ? "arrow.down" : "arrow.down.to.line")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(dropTargeted ? Theme.end : Look.muted)
                    Text(dropTargeted ? "Release to add" : "Drop files here").font(Look.display(24))
                } else {
                    DropWell(targeted: dropTargeted)
                    Text(dropTargeted ? "Release to add" : "Drop files here").font(Look.display(17, weight: Look.style == .clay ? .heavy : .semibold))
                }
                Button(Look.isAtelier ? "or choose from Finder" : "Choose from Finder") { addFiles() }
                    .buttonStyle(SecondaryStyle())
                    .keyboardShortcut("o")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Kicker("\(files.count) file\(files.count == 1 ? "" : "s")")
                    Spacer()
                    Button("Add more") { addFiles() }
                        .buttonStyle(SecondaryStyle())
                        .keyboardShortcut("o")
                }
                VStack(spacing: 0) {
                    ForEach(files, id: \.self) { file in
                        FileRow(file: file) { files.removeAll { $0 == file } }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 170)
        .padding(Space.xl)
        .background {
            if Look.isAtelier {
                ZStack {
                    Rectangle().fill(dropTargeted ? Theme.secondaryTint : Look.background)
                    if files.isEmpty { Stripes().foregroundStyle(Look.stripe) }
                    Rectangle().strokeBorder(dropTargeted ? Look.ink : Look.hairline, lineWidth: 1)
                }
            } else {
                let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
                LookSurface(shape: shape, inset: true)
                    .overlay(shape.strokeBorder(Theme.secondaryText, lineWidth: dropTargeted ? 2 : 0))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { files += await Self.fileURLs(from: providers).filter { !files.contains($0) } }
            return true
        }
        .motion(Motion.fast, value: dropTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(files.isEmpty ? "Drop area. Drop files here or choose files." : "\(files.count) files ready")
    }

    /// A message or link to send along, written on an underlined line.
    @ViewBuilder private var composer: some View {
        if Look.isAtelier { underlinedComposer } else { fieldComposer }
    }

    /// The other styles: a rounded field in the style's container.
    private var fieldComposer: some View {
        TextField("", text: $text, prompt: Text("Add a message or paste a link").foregroundStyle(Look.muted), axis: .vertical)
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($typing)
            .lookCard(padding: 16)
            .overlay(RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous)
                .strokeBorder(Theme.secondaryText, lineWidth: typing ? 2 : 0))
            .motion(Motion.fast, value: typing)
    }

    private var underlinedComposer: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Kicker("Message")
            TextField("", text: $text,
                      prompt: Text("Add a message or paste a link").font(Look.display(16)).italic(),
                      axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($typing)
                .padding(.vertical, 6)
            Rectangle()
                .fill(typing ? Look.ink : Look.hairline)
                .frame(height: 1)
        }
        .motion(Motion.fast, value: typing)
    }

    private var bottomBar: some View {
        HStack(spacing: Space.md) {
            Button {
                guard let peer = selected else { return }
                Task { await model.sendClipboard(to: peer) }
            } label: {
                if Look.isAtelier { Text("Send clipboard") } else { Label("Send clipboard", systemImage: "doc.on.clipboard") }
            }
            .buttonStyle(SecondaryStyle())
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .hoverHint("Send what's on the clipboard (⇧⌘V)")
            .disabled(selected == nil || model.isSending)

            Spacer()

            Button {
                guard let peer = selected else { return }
                Task { await sendStaged(to: peer) }
            } label: {
                HStack(spacing: Space.sm) {
                    Text(selected.map { "Send to \($0.name)" } ?? "Send")
                    if model.isSending { ProgressView().controlSize(.small) }
                    else if Look.isAtelier { Image(systemName: "arrow.right").foregroundStyle(Theme.end) }
                    else { Image(systemName: "paperplane.fill") }
                }
            }
            .buttonStyle(PrimaryStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .hoverHint("Send the files and message (⌘↩)")
            .disabled(selected == nil || !hasContent || model.isSending)
        }
    }

    // MARK: Actions

    /// "Missing Token": open Settings at that device's token.
    private func fixToken(_ peer: Peer) {
        model.settings.tokenRequest = peer.id
        openSettings()
        bringToFront()
    }

    private func addFiles() {
        files += model.pickFiles().filter { !files.contains($0) }
    }

    private func sendStaged(to peer: Peer) async {
        var payloads: [SendPayload] = []
        if !trimmed.isEmpty {
            if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
                payloads.append(.url(url))
            } else {
                payloads.append(.text(text))
            }
        }
        if !files.isEmpty { payloads.append(.files(files)) }
        if await model.send(payloads, to: peer) {
            Motion.perform {
                files = []
                text = ""
            }
        }
    }

    static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
               let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            }
        }
        return urls
    }
}

/// A device as a text tab: the selected one is underlined with a small dot in the theme's
/// second color. Dropping files on it sends them to that device immediately.
private struct DeviceTab: View {
    var peer: Peer
    var selected: Bool
    var waiting: Int
    var onSelect: () -> Void
    var onDropFiles: ([URL]) -> Void
    var onClearWaiting: () -> Void
    var onMissingToken: () -> Void
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        Group {
            if Look.isAtelier { tab } else { card }
        }
        .onHover { hovering = $0 }
        .hoverHint("Send to \(peer.name). Drop files here to send them right away.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(peer.name), \(Theme.platformName(peer.platform))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                let urls = await SendView.fileURLs(from: providers)
                if !urls.isEmpty { onDropFiles(urls) }
            }
            return true
        }
        .motion(Motion.fast, value: selected)
        .motion(Motion.fast, value: targeted)
        .motion(Motion.fast, value: hovering)
    }

    /// Material, Clay and Spatial: a card; the selected one takes the theme's second color.
    private var card: some View {
        let active = selected || targeted
        let shape = RoundedRectangle(cornerRadius: Look.style == .material ? 16 : 20, style: .continuous)
        return Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: active && selected ? "checkmark" : Theme.symbol(for: peer))
                    .font(.system(size: 18, weight: .medium))
                Spacer(minLength: Space.xs)
                Text(peer.name).font(.system(size: 14, weight: Look.style == .clay ? .bold : .semibold)).lineLimit(1)
                Text(targeted ? "Release to send now" : Theme.platformName(peer.platform))
                    .font(.system(size: 11))
                    .opacity(peer.isPaired || targeted ? 1 : 0)
                    .foregroundStyle(active ? Look.selectedInk.opacity(0.75) : Look.muted)
            }
            .foregroundStyle(active ? Look.selectedInk : Look.ink)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background {
                if active {
                    shape.fill(Look.selectedFill)
                        .shadow(color: Look.style == .spatial ? Theme.end.opacity(0.35) : .clear, radius: 14)
                } else if Look.style == .material {
                    shape.fill(hovering ? Look.container : .clear)
                        .overlay(shape.strokeBorder(Look.hairline, lineWidth: 1))
                } else {
                    LookSurface(shape: shape).opacity(hovering ? 0.8 : 1)
                }
            }
            .modifier(ClayShadow())
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if waiting > 0 {
                WaitingBadge(count: waiting, peerName: peer.name, onClear: onClearWaiting).padding(10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !peer.isPaired && !targeted { MissingTokenButton(action: onMissingToken).padding(14) }
        }
    }

    /// Atelier: an underlined text tab.
    private var tab: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(spacing: Space.sm) {
                        Image(systemName: Theme.symbol(for: peer))
                            .font(.system(size: 13))
                            .foregroundStyle(selected || targeted ? Look.ink : Look.muted)
                        Text(peer.name)
                            .font(Look.display(18))
                            .foregroundStyle(selected || targeted || hovering ? Look.ink : Look.muted)
                            .lineLimit(1)
                        if selected {
                            Circle().fill(Theme.end).frame(width: 6, height: 6)
                        }
                    }
                    Rectangle()
                        .fill(selected || targeted ? Theme.primaryButton : hovering ? Look.hairline : .clear)
                        .frame(height: 2)
                }
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if targeted {
                Text("Release to send now").font(.system(size: 11)).foregroundStyle(Look.muted)
            } else if !peer.isPaired {
                MissingTokenButton(action: onMissingToken)
            } else if waiting > 0 {
                WaitingBadge(count: waiting, peerName: peer.name, onClear: onClearWaiting)
            } else {
                Text(Theme.platformName(peer.platform)).font(.system(size: 11)).foregroundStyle(Look.muted)
            }
        }
    }
}

/// The plus after the device tiles: opens Pair a phone, for a phone's browser or the Droprr app.
private struct AddDeviceTile: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if Look.isAtelier { tab } else { card }
        }
        .onHover { hovering = $0 }
        .hoverHint("Add a phone or a browser with a QR code")
        .accessibilityLabel("Add a device")
        .motion(Motion.fast, value: hovering)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Look.style == .material ? 16 : 20, style: .continuous)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                Spacer(minLength: Space.xs)
                Text("Add a device").font(.system(size: 14, weight: Look.style == .clay ? .bold : .semibold)).lineLimit(1)
                Text("Phone or browser").font(.system(size: 11)).foregroundStyle(Look.muted)
            }
            .foregroundStyle(hovering ? Look.ink : Look.muted)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background {
                shape.fill(hovering ? Look.container : .clear)
                    .overlay(shape.strokeBorder(Look.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    private var tab: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "plus").font(.system(size: 13))
                        Text("Add a device").font(Look.display(18)).lineLimit(1)
                    }
                    .foregroundStyle(hovering ? Look.ink : Look.muted)
                    Rectangle().fill(hovering ? Look.hairline : .clear).frame(height: 2)
                }
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("Phone or browser").font(.system(size: 11)).foregroundStyle(Look.muted)
        }
    }
}

/// A staged file: its type icon, name, and a remove button, over a hairline.
private struct FileRow: View {
    var file: URL
    var onRemove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RowSeparator()
            HStack(spacing: Space.md) {
                Image(systemName: Theme.symbol(for: ReceivedItem(kind: .file(file))))
                    .foregroundStyle(Look.muted)
                    .frame(width: 18)
                Text(file.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(HoverButtonStyle(.plain))
                    .foregroundStyle(Look.muted)
                    .accessibilityLabel("Remove \(file.lastPathComponent)")
            }
            .padding(.vertical, Space.sm)
        }
    }
}

/// The icon in the drop zone for the card styles: a tinted well that lights up while dragging.
private struct DropWell: View {
    var targeted: Bool

    var body: some View {
        let spatial = Look.style == .spatial
        let shape = RoundedRectangle(cornerRadius: Look.style == .material ? 16 : 28, style: .continuous)
        Image(systemName: targeted ? "arrow.down" : "arrow.down.to.line")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(spatial ? Color.white : Theme.secondaryText)
            .frame(width: 56, height: 56)
            .background(shape.fill(spatial ? Color.white.opacity(0.18) : Theme.secondaryTint))
            .shadow(color: spatial ? Theme.end.opacity(0.45) : .clear, radius: 14)
            .modifier(ClayShadow())
            .scaleEffect(targeted ? 1.08 : 1)
            .accessibilityHidden(true)
    }
}

/// Equal-width items in rows of `columns`, wrapping as needed (the card styles' device grid).
private struct GridFlowLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 544
        let itemWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var height: CGFloat = 0
        for row in stride(from: 0, to: subviews.count, by: columns) {
            let rowHeight = subviews[row..<min(row + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }.max() ?? 0
            height += rowHeight + (row > 0 ? spacing : 0)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let itemWidth = (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var y = bounds.minY
        for row in stride(from: 0, to: subviews.count, by: columns) {
            let items = subviews[row..<min(row + columns, subviews.count)]
            let rowHeight = items.map { $0.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }.max() ?? 0
            for (offset, item) in items.enumerated() {
                item.place(at: CGPoint(x: bounds.minX + CGFloat(offset) * (itemWidth + spacing), y: y),
                           proposal: ProposedViewSize(width: itemWidth, height: rowHeight))
            }
            y += rowHeight + spacing
        }
    }
}
