import SwiftUI
import AppKit
import CurrentCore

/// ⌘K accelerator. Opens instantly with no animation — keyboard surfaces
/// used hundreds of times a day must feel like part of the user's hands.
struct CommandPalette: View {
    @EnvironmentObject private var app: AppEnvironment
    @Binding var isVisible: Bool
    let commands: [Command]

    struct Command: Identifiable {
        let id = UUID()
        let title: String
        var shortcutHint: String?
        let action: () -> Void

        init(_ title: String, shortcutHint: String? = nil, action: @escaping () -> Void) {
            self.title = title
            self.shortcutHint = shortcutHint
            self.action = action
        }
    }

    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var isFocused: Bool

    private var filtered: [Command] {
        guard !query.isEmpty else { return commands }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Type a command", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($isFocused)
                        .onSubmit { run(highlightedIndex) }
                }
                .padding(14)

                Divider()

                if filtered.isEmpty {
                    Text("No matching command")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                } else {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                        row(command: command, index: index)
                    }
                }

                Divider()
                HStack {
                    Text("↑↓ navigate · ↩ run · esc close")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: Layout.cornerL + 4, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.cornerL + 4, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5))
            )
            .frame(width: 480)
            .padding(.top, 90)
        }
        .onAppear {
            query = ""
            highlightedIndex = 0
            isFocused = true
        }
        .background(PaletteKeyHandler(
            onUp: { move(-1) },
            onDown: { move(1) },
            onEscape: { close() },
            onReturn: { run(highlightedIndex) }
        ))
    }

    private func row(command: Command, index: Int) -> some View {
        Button {
            run(index)
            close()
        } label: {
            HStack {
                Text(command.title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                if let hint = command.shortcutHint {
                    Text(hint)
                        .font(.caption.tabularNumerics())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(index == highlightedIndex ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { highlightedIndex = index }
        }
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        highlightedIndex = max(0, min(filtered.count - 1, highlightedIndex + delta))
    }

    private func run(_ index: Int) {
        guard filtered.indices.contains(index) else { return }
        filtered[index].action()
        close()
    }

    private func close() {
        isVisible = false
    }
}

// MARK: - Key routing for the palette

private struct PaletteKeyHandler: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void
    var onEscape: () -> Void
    var onReturn: () -> Void

    final class HandlerView: NSView {
        var handlers: (Int, Int, Int, Int) -> Void = { _, _, _, _ in }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126: handlers(1, 0, 0, 0)      // up
            case 125: handlers(0, 1, 0, 0)      // down
            case 53: handlers(0, 0, 1, 0)       // escape
            case 36: handlers(0, 0, 0, 1)       // return
            default: super.keyDown(with: event)
            }
        }

        override var acceptsFirstResponder: Bool { true }
    }

    func makeNSView(context: Context) -> NSView {
        let view = HandlerView()
        view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        view.handlers = { up, down, esc, ret in
            if up == 1 { onUp() }
            if down == 1 { onDown() }
            if esc == 1 { onEscape() }
            if ret == 1 { onReturn() }
        }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HandlerView)?.handlers = { up, down, esc, ret in
            if up == 1 { onUp() }
            if down == 1 { onDown() }
            if esc == 1 { onEscape() }
            if ret == 1 { onReturn() }
        }
    }
}
