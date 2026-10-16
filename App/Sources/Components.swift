import AppKit
import AmphoraCore
import SwiftUI

// Motion rules (Apple's fluid-interface guidance, native edition):
// - status changes use a critically damped spring: no overshoot, nothing bouncy on data;
// - symbol effects only on meaningful moments (a model became ready), never on idle UI;
// - SwiftUI and SF Symbol effects already honour Reduce Motion.
extension Animation {
    static let ui = Animation.spring(duration: 0.35, bounce: 0)
}

/// A device glyph on a soft tile, so rows scan by shape before text.
struct DeviceGlyph: View {
    let family: DeviceModel.Family

    var body: some View {
        Image(systemName: family == .iPhone ? "iphone" : "ipad")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

/// Reminders-style circle: the whole row reads as "kept" or not at a glance.
struct KeepButton: View {
    let isOn: Bool
    let isLocked: Bool
    var lockReason: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .accessibilityLabel("Keep current")
        .accessibilityValue(isOn ? "On" : "Off")
        .help(isLocked ? (lockReason ?? "Set by your organization")
              : isOn ? "Stop keeping this model current" : "Keep this model current")
    }
}

/// One compact status per model. Text plus symbol plus colour, so colour never carries meaning alone.
struct StatusBadge: View {
    let status: AppModel.Status
    let target: String
    let isKept: Bool

    var body: some View {
        content
            .animation(.ui, value: status)
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case let .ready(version):
            pill("Ready · \(version)", symbol: "checkmark.circle.fill", tint: .green)
                .help("The \(version) restore file is downloaded and verified")
        case let .outdated(version):
            pill("Update available: \(version) → \(target)", symbol: "arrow.up.circle.fill", tint: .orange)
                .help("The file on disk is \(version). The next sync downloads \(target).")
        case .missing:
            if isKept {
                pill("Not downloaded · \(target)", symbol: "arrow.down.circle", tint: .secondary)
                    .help("The \(target) restore file isn't on this Mac yet")
            } else {
                Text(target)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .queued:
            pill("Waiting", symbol: "clock", tint: .secondary)
        case let .downloading(fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 96)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: fraction))
                    .frame(width: 40, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Downloading")
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            pill("Failed", symbol: "exclamationmark.triangle.fill", tint: .red)
                .help(message)
        }
    }

    private func pill(_ text: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(text).monospacedDigit()
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: .capsule)
    }
}

/// A number with its label: the number is the point, so it carries the weight.
struct StatTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// One model in a list. Actions appear on hover and in the context menu, the way Mail and Finder do it.
struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let row: AppModel.Row
    @State private var hovering = false

    private var isKept: Bool { model.isKept(row.id) }
    private var jamfCount: Int? { model.modelSource == .jamf ? model.jamfCounts[row.id] : nil }
    private var fileURL: URL? { model.fileURL(for: row.id) }
    private var status: AppModel.Status { model.status[row.id] ?? .missing }
    private var canDownload: Bool {
        switch status {
        case .ready, .queued, .downloading, .verifying: return false
        default: return !model.isBusy
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // In Jamf mode the inventory decides, so there is nothing to tick.
            if model.modelSource == .curated {
                KeepButton(isOn: isKept, isLocked: model.selectionLocked, lockReason: model.selectionLockReason) {
                    withAnimation(.ui) { model.toggleKept(row.id) }
                }
            }
            DeviceGlyph(family: row.device.family)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.device.name)
                    .fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(row.device.identifier)
                        .font(.caption.monospaced())
                    if let jamfCount {
                        Text("· \(plural(jamfCount, "device")) in Jamf")
                            .font(.caption)
                    } else if model.modelSource == .jamf, let until = model.jamfRetained[row.id] {
                        Text("· left Jamf Pro, kept until \(until.formatted(.dateTime.day().month()))")
                            .font(.caption)
                            .help("No device of this model is in Jamf Pro any more. Its restore file stays for "
                                  + "\(plural(model.jamfGraceDays, "day")) in case a device is still waiting to be "
                                  + "restored, then it's deleted. Change this in Settings.")
                    }
                    if row.isLegacy {
                        Text("· final release for this model")
                            .font(.caption)
                            .help("Current releases no longer support this model. Apple still signs its last release, so it can be restored.")
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            StatusBadge(status: status, target: row.targetVersion, isKept: isKept)
            Button {
                Task { await model.downloadNow(row.id) }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .disabled(!canDownload)
            .opacity(hovering && canDownload ? 1 : 0)
            .accessibilityLabel("Download now")
            .help(isKept ? "Download now" : "Download now. Removed at the next sync unless you keep this model current.")
            .overlay {
                // Where the download button sits, a grip says "this row can be dragged" once a file exists.
                if fileURL != nil && !canDownload && hovering {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .fileDrag(fileURL)
        .help(fileURL == nil ? "" : "Drag onto a device in Apple Configurator to restore with this IPSW")
        .contextMenu {
            if model.modelSource == .curated {
                Button(isKept ? "Remove from My Devices" : "Add to My Devices") {
                    withAnimation(.ui) { model.toggleKept(row.id) }
                }
                .disabled(model.selectionLocked)
            }
            Button("Download Now") {
                Task { await model.downloadNow(row.id) }
            }
            .disabled(!canDownload)
            if let url = fileURL {
                Button("Show IPSW in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            if model.fileName(for: row.id) != nil {
                Button(model.hasPartialFile(for: row.id) ? "Delete Partial Download…" : "Delete Downloaded IPSW…",
                       role: .destructive) {
                    model.requestDelete(model: row.id)
                }
            }
            Divider()
            Button("Copy Identifier") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.id, forType: .string)
            }
        }
    }
}

/// One toolbar control for a running sync: a ring that fills with overall progress around a stop square,
/// like Safari's downloads. Spins while the plan is being worked out; click to cancel.
struct SyncProgressButton: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var showDetail = false

    private var fraction: Double? {
        guard let progress = model.progress, progress.fileCount > 0 else { return nil }
        return progress.fraction
    }

    var body: some View {
        Button {
            model.cancel()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                if let fraction {
                    Circle()
                        .trim(from: 0, to: max(0.02, fraction))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.ui, value: fraction)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(1.15)
                }
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: 6, height: 6)
            }
            .frame(width: 18, height: 18)
        }
        // No tooltip: the hover popover below carries the live details (a changing tooltip flickers).
        .accessibilityLabel("Stop sync")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "Checking")
        .onHover { inside in
            hovering = inside
            if inside {
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if hovering { showDetail = true }
                }
            } else {
                showDetail = false
            }
        }
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            SyncDetailPopover()
                .environment(model)
        }
    }
}

/// Live sync details. Updates in place, unlike a tooltip.
private struct SyncDetailPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = model.progress, progress.fileCount > 0 {
                Text("Downloading \(min(progress.finished.count + 1, progress.fileCount)) of \(progress.fileCount)")
                    .fontWeight(.semibold)
                if let current = progress.current {
                    Text(current)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ProgressView(value: progress.fraction)
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) of "
                         + ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))
                    Spacer()
                    Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                }
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking for new releases…")
                }
            }
            Text("Click to stop. Downloads resume next time.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 280)
    }
}

extension View {
    /// Lets the view be dragged out as a file, e.g. onto a device in Apple Configurator. No-op without a file.
    @ViewBuilder
    func fileDrag(_ url: URL?) -> some View {
        if let url {
            onDrag { NSItemProvider(object: url as NSURL) }
        } else {
            self
        }
    }
}

func plural(_ count: Int, _ word: String) -> String {
    "\(count) \(word)\(count == 1 ? "" : "s")"
}

/// Says plainly why IPSWs aren't reaching Apple Configurator, and what fixes it.
struct ConfiguratorAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.configuratorBlocked, let access = model.configuratorAccess {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: access == .denied ? "lock.shield" : "questionmark.app.dashed")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(access == .denied ? "IPSWs can't reach Apple Configurator yet"
                                           : "Apple Configurator hasn't been opened on this Mac")
                        .fontWeight(.semibold)
                    Text(access == .denied
                         ? "macOS protects Configurator's folder. Turn on Full Disk Access for Amphora, then reopen the app. On managed Macs, a Jamf PPPC profile does this for you."
                         : "Open Apple Configurator once so it creates its folders, then sync again.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if access == .denied {
                    Button("Set Up…") { model.showConfiguratorSetup = true }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Check Again") { model.checkConfiguratorAccess() }
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: 12))
        }
    }
}
