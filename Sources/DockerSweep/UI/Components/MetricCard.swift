import AppKit
import SwiftUI

struct MetricCard: View {
  let title: String
  let value: String
  let detail: String
  let symbol: String
  let tint: Color

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.title3.weight(.semibold))
        .foregroundStyle(tint)
        .frame(width: 30, height: 30)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Text(value).font(.headline.monospacedDigit())
        Text(detail).font(.caption2).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
  }
}

enum Formatters {
  static func bytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  static func relative(_ date: Date?) -> String {
    guard let date else { return "Never" }
    return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
  }
}
