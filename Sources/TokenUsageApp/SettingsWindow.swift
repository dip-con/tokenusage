import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        Form {
            Section {
                ForEach(Array(model.settings.providers.order.enumerated()), id: \.element) { index, provider in
                    ProviderSettingsRow(
                        provider: provider,
                        isEnabled: Binding(
                            get: { model.settings.providers.isEnabled(provider) },
                            set: { model.setProvider(provider, enabled: $0) }
                        ),
                        canMoveUp: index > 0,
                        canMoveDown: index < model.settings.providers.order.count - 1,
                        move: { model.moveProvider(provider, by: $0) }
                    )
                }
            } header: {
                Text("프로바이더")
            } footer: {
                Text("위에서 아래 순서가 팝오버의 위에서 아래, 메뉴 막대의 왼쪽에서 오른쪽 순서입니다. 끈 프로바이더는 조회하지 않습니다.")
                    .font(PopoverDesignSystem.Typography.detail)
                    .foregroundStyle(PopoverDesignSystem.Palette.secondary)
            }

            Section {
                ForEach(model.settings.providers.order) { provider in
                    Toggle(
                        provider.displayName,
                        isOn: Binding(
                            get: {
                                model.settings.providers.isEnabled(provider)
                                    && model.settings.providers.showsInMenuBar(provider)
                            },
                            set: { model.setProvider(provider, showsInMenuBar: $0) }
                        )
                    )
                    .disabled(!model.settings.providers.isEnabled(provider))
                    .accessibilityLabel("\(provider.displayName) 메뉴 막대에 표시")
                    .accessibilityIdentifier("settings-menubar-\(provider.rawValue)")
                }
            } header: {
                Text("메뉴 막대에 표시")
            } footer: {
                Text("끄면 팝오버에는 남기고 메뉴 막대 숫자에서만 빼어 폭을 줄입니다.")
                    .font(PopoverDesignSystem.Typography.detail)
                    .foregroundStyle(PopoverDesignSystem.Palette.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("settings-window-content")
    }
}

private struct ProviderSettingsRow: View {
    let provider: ProviderKind
    @Binding var isEnabled: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: PopoverDesignSystem.Spacing.small) {
            Toggle(isOn: $isEnabled) {
                Text(provider.displayName)
                    .foregroundStyle(
                        isEnabled ? PopoverDesignSystem.Palette.primary : PopoverDesignSystem.Palette.secondary
                    )
            }
            .toggleStyle(.switch)
            .accessibilityLabel("\(provider.displayName) 표시")
            .accessibilityIdentifier("settings-provider-enabled-\(provider.rawValue)")
            Spacer(minLength: 0)
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(!canMoveUp)
                .accessibilityLabel("\(provider.displayName) 위로")
                .accessibilityIdentifier("settings-provider-up-\(provider.rawValue)")
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .disabled(!canMoveDown)
                .accessibilityLabel("\(provider.displayName) 아래로")
                .accessibilityIdentifier("settings-provider-down-\(provider.rawValue)")
        }
        .buttonStyle(.borderless)
    }
}

@MainActor
final class SettingsWindowController {
    private let model: AppViewModel
    private var window: NSWindow?

    init(model: AppViewModel) {
        self.model = model
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // An accessory (menu bar) app has to activate itself, or the window opens behind others.
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView(model: model))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = "Token Usage 설정"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("settings-window")
        window.center()
        return window
    }
}
