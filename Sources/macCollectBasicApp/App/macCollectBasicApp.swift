import AppKit
import SwiftUI

@main
struct MacCollectBasicApp: App {
    @AppStorage("TextScale") private var textScale = 1.0

    var body: some Scene {
        WindowGroup {
            BasicSystemOverviewView()
                .environment(\.appTextScale, textScale)
                .dynamicTypeSize(dynamicTypeSize(for: textScale))
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Increase Text Size") { textScale = min(1.6, roundedScale(textScale + 0.1)) }
                    .keyboardShortcut("+", modifiers: [.control])
                Button("Decrease Text Size") { textScale = max(0.8, roundedScale(textScale - 0.1)) }
                    .keyboardShortcut("-", modifiers: [.control])
                Button("Reset Text Size") { textScale = 1.0 }
                    .keyboardShortcut("0", modifiers: [.control])
            }
        }
    }

    private func roundedScale(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func dynamicTypeSize(for scale: Double) -> DynamicTypeSize {
        switch scale {
        case ..<0.9: return .xSmall
        case ..<1.0: return .medium
        case ..<1.1: return .large
        case ..<1.2: return .xLarge
        case ..<1.3: return .xxLarge
        case ..<1.4: return .xxxLarge
        default: return .accessibility1
        }
    }
}
