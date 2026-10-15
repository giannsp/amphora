import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem {
                    Button("Clear", systemImage: "trash") { model.clearLog() }
                        .disabled(model.log.isEmpty)
                        .help("Clear the activity log")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.log.isEmpty {
            ContentUnavailableView("No activity yet", systemImage: "list.bullet.rectangle",
                                   description: Text("Syncs and downloads are logged here."))
        } else {
            ScrollViewReader { proxy in
                List(Array(model.log.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .id(index)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onAppear { proxy.scrollTo(model.log.count - 1, anchor: .bottom) }
                .onChange(of: model.log.count) { _, count in
                    withAnimation(.ui) { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }
}
