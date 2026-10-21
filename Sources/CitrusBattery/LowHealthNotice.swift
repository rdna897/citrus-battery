import AppKit
import SwiftUI

/// Shown when battery health falls below 80%, with a replacement search.
struct LowHealthNotice: View {
    let healthFraction: Double?
    /// Model to search for, e.g. "MacBook Air (13-inch, M4, 2025)".
    let model: String
    /// Remembers dismissal per battery.
    let batteryKey: String
    @AppStorage("dismissedLowHealthNotices") private var dismissed = ""

    static let threshold = 0.8

    var body: some View {
        if let health = healthFraction, health < Self.threshold, !dismissedKeys.contains(batteryKey) {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Battery health is \(Int((health * 100).rounded()))%. Apple batteries are designed to keep "
                        + "about 80% of their capacity over their rated life, so expect less time between charges.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                HStack {
                    Button("Find a Replacement…") { ReplacementSearch.open(model: model) }
                    Button("Don't Show Again") { dismissed = (dismissedKeys + [batteryKey]).joined(separator: "\n") }
                }
                .controlSize(.small)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var dismissedKeys: [String] {
        dismissed.split(separator: "\n").map(String.init)
    }
}

enum ReplacementSearch {
    /// Searches iFixit, which lists batteries and guides by exact model.
    static func url(model: String) -> URL? {
        var components = URLComponents(string: "https://www.ifixit.com/Search")
        components?.queryItems = [URLQueryItem(name: "query", value: "\(model) battery")]
        return components?.url
    }

    static func open(model: String) {
        if let url = url(model: model) { NSWorkspace.shared.open(url) }
    }
}
