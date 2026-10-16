import AppKit
import SwiftUI

/// A paper card under the notebook that asks for its password: to set one
/// the first time, to open it, or to change it.
@MainActor
final class PasswordCard: NSPanel {
    enum Mode { case create, unlock, change }

    let model: PasswordModel
    var onCancel: (() -> Void)?

    init(mode: Mode, onSubmit: @escaping (PasswordModel) -> Void) {
        model = PasswordModel(mode: mode)
        super.init(contentRect: CGRect(origin: .zero, size: PasswordCardView.size(for: mode)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        appearance = NSAppearance(named: .aqua)
        let view = PasswordCardView(model: model, submit: { [weak self] in
            guard let self else { return }
            onSubmit(self.model)
        }, cancel: { [weak self] in self?.cancelOperation(nil) })
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    /// Just under the notebook, kept on its screen.
    func place(under notebook: CGRect) {
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(notebook) } ?? NSScreen.main
        var origin = NSPoint(x: notebook.midX - size.width / 2, y: notebook.minY - size.height + 10)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        setFrameOrigin(origin)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
        onCancel?()
    }
}

@MainActor
final class PasswordModel: ObservableObject {
    let mode: PasswordCard.Mode
    @Published var old = ""
    @Published var first = ""
    @Published var second = ""
    @Published var error: String?
    @Published var working = false
    @Published var shakes = 0
    /// Waiting for a finger on Touch ID; the password still works meanwhile.
    @Published var fingerprint = false

    init(mode: PasswordCard.Mode) { self.mode = mode }

    func fail(_ message: String) {
        error = message
        working = false
        shakes += 1
        if mode == .unlock { first = "" }
    }
}

struct PasswordCardView: View {
    @ObservedObject var model: PasswordModel
    let submit: () -> Void
    let cancel: () -> Void
    @FocusState private var focus: Field?

    enum Field { case old, first, second }

    static func size(for mode: PasswordCard.Mode) -> CGSize {
        switch mode {
        case .unlock: return CGSize(width: 350, height: 230)
        case .create: return CGSize(width: 320, height: 300)
        case .change: return CGSize(width: 320, height: 290)
        }
    }

    private var title: String {
        switch model.mode {
        case .unlock: return "Записная книжка заперта"
        case .create: return "Придумайте пароль"
        case .change: return "Новый пароль"
        }
    }

    private var action: String {
        switch model.mode {
        case .unlock: return "Открыть"
        case .create: return "Запереть"
        case .change: return "Сменить"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.system(size: 15, weight: .medium))
                Text(title).font(.custom(NotebookLook.hand, size: 21))
            }
            .foregroundStyle(Color(nsColor: NotebookLook.ink))

            if model.mode == .create {
                Text("Без пароля заметки не открыть никому. Восстановить его нельзя — запишите в надёжное место.")
                    .font(.custom(NotebookLook.body, size: 11))
                    .foregroundStyle(Color(nsColor: NotebookLook.pencil))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.fingerprint {
                HStack(spacing: 10) {
                    Image(systemName: "touchid")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Color(red: 0.78, green: 0.30, blue: 0.32))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Приложите палец").font(.custom(NotebookLook.hand, size: 17))
                        Text("или введите пароль").font(.custom(NotebookLook.body, size: 11))
                            .foregroundStyle(Color(nsColor: NotebookLook.pencil))
                    }
                    .foregroundStyle(Color(nsColor: NotebookLook.ink))
                }
                .transition(.opacity)
            }
            if model.mode == .change {
                field("Старый пароль", text: $model.old, as: .old)
            }
            field(model.mode == .unlock ? "Пароль" : "Новый пароль, от \(8) символов", text: $model.first, as: .first)
            if model.mode != .unlock {
                field("Ещё раз", text: $model.second, as: .second)
            }

            HStack {
                Text(model.error ?? " ")
                    .font(.custom(NotebookLook.body, size: 11))
                    .foregroundStyle(Color(red: 0.70, green: 0.25, blue: 0.20))
                    .lineLimit(2)
                Spacer()
                if model.working { ProgressView().controlSize(.small) }
                Button("Отмена", action: cancel)
                    .buttonStyle(.plain)
                    .font(.custom(NotebookLook.body, size: 12))
                    .foregroundStyle(Color(nsColor: NotebookLook.pencil))
                Button(action) { if !model.working { submit() } }
                    .buttonStyle(.plain)
                    .font(.custom(NotebookLook.hand, size: 17))
                    .foregroundStyle(Color(nsColor: NotebookLook.ink))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: NotebookLook.ink).opacity(0.5), lineWidth: 1))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: NotebookLook.paper))
                .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
        )
        .padding(12)
        .modifier(Shake(amount: CGFloat(model.shakes)))
        .animation(.linear(duration: 0.35), value: model.shakes)
        .animation(.easeOut(duration: 0.2), value: model.fingerprint)
        .disabled(model.working)
        .onAppear { focus = model.mode == .change ? .old : .first }
        .onChange(of: model.working) { _, working in if !working { focus = model.mode == .change ? .old : .first } }
    }

    private func field(_ prompt: String, text: Binding<String>, as which: Field) -> some View {
        SecureField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.custom(NotebookLook.body, size: 14))
            .foregroundStyle(Color(nsColor: NotebookLook.ink))
            .focused($focus, equals: which)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: NotebookLook.dots)).frame(height: 1) }
            .onSubmit {
                switch which {
                case .old: focus = .first
                case .first where model.mode != .unlock: focus = .second
                default: if !model.working { submit() }
                }
            }
    }
}

/// A head shake for a wrong password.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(amount * .pi * 6), y: 0))
    }
}
