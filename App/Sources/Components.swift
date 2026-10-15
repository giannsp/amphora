import AppKit
import IPSWMirrorCore
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
        .help(isLocked ? "Set by your organization"
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
            pill(version, symbol: "checkmark.circle.fill", tint: .green)
        case let .outdated(version):
            pill("\(version) → \(target)", symbol: "arrow.up.circle.fill", tint: .orange)
        case .missing:
            if isKept {
                pill("\(target) needed", symbol: "arrow.down.circle", tint: .orange)
            } else {
                Text(target)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .queued:
            pill("Queued", symbol: "clock", tint: .secondary)
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

    private var isKept: Bool { model.selected.contains(row.id) }
    private var status: AppModel.Status { model.status[row.id] ?? .missing }
    private var canDownload: Bool {
        switch status {
        case .ready, .queued, .downloading, .verifying: return false
        default: return !model.isBusy
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            KeepButton(isOn: isKept, isLocked: model.selectionManaged) {
                withAnimation(.ui) { model.toggleKept(row.id) }
            }
            DeviceGlyph(family: row.device.family)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.device.name)
                    .fontWeight(.medium)
                Text(row.device.identifier)
                    .font(.caption.monospaced())
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
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .contextMenu {
            Button(isKept ? "Stop Keeping Current" : "Keep Current") {
                withAnimation(.ui) { model.toggleKept(row.id) }
            }
            .disabled(model.selectionManaged)
            Button("Download Now") {
                Task { await model.downloadNow(row.id) }
            }
            .disabled(!canDownload)
            if model.fileName(for: row.id) != nil {
                Button("Delete Downloaded IPSW…", role: .destructive) {
                    model.requestDelete(model: row.id)
                }
                .disabled(model.isBusy)
            }
            Divider()
            Button("Copy Identifier") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.id, forType: .string)
            }
        }
    }
}

func plural(_ count: Int, _ word: String) -> String {
    "\(count) \(word)\(count == 1 ? "" : "s")"
}
