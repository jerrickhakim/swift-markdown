import SwiftUI

struct MarkdownFetchErrorMessage: View {
  let message: String
  let theme: MarkdownTheme

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Text(message)
      .font(.footnote)
      .foregroundStyle(theme.fetch.errorText.resolve(for: colorScheme))
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct MarkdownRetryButton: View {
  let theme: MarkdownTheme
  let action: () -> Void

  var body: some View {
    Button("Retry", action: action)
      .buttonStyle(MarkdownRetryButtonStyle(theme: theme))
  }
}

private struct MarkdownRetryButtonStyle: ButtonStyle {
  let theme: MarkdownTheme

  @Environment(\.colorScheme) private var colorScheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline.weight(.semibold))
      .foregroundStyle(theme.fetch.actionForeground.resolve(for: colorScheme))
      .frame(maxWidth: .infinity)
      .padding(.vertical, 16)
      .background(
        .ultraThinMaterial,
        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(theme.fetch.actionBorder.resolve(for: colorScheme), lineWidth: 1)
      }
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
  }
}
