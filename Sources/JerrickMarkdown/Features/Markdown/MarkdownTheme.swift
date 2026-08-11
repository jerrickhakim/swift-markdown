import SwiftUI

/// Color tokens for the markdown renderer.
///
/// Themes are immutable and are not observable. Views pass one shared reference
/// through the render tree, while rendering only selects an already-stored light
/// or dark color. No theme allocation or observation enters the streaming path.
public final class MarkdownTheme: @unchecked Sendable, Equatable {
  public struct AdaptiveColor: Equatable {
    public let light: Color
    public let dark: Color

    public init(light: Color, dark: Color) {
      self.light = light
      self.dark = dark
    }

    public func resolve(for colorScheme: ColorScheme) -> Color {
      colorScheme == .dark ? dark : light
    }
  }

  public struct CodeColors: Equatable {
    public let headerBackground: AdaptiveColor
    public let bodyBackground: AdaptiveColor
    public let label: AdaptiveColor
    public let actionForeground: AdaptiveColor
    public let actionBackground: AdaptiveColor
    public let copiedForeground: AdaptiveColor

    public init(
      headerBackground: AdaptiveColor,
      bodyBackground: AdaptiveColor,
      label: AdaptiveColor,
      actionForeground: AdaptiveColor,
      actionBackground: AdaptiveColor,
      copiedForeground: AdaptiveColor
    ) {
      self.headerBackground = headerBackground
      self.bodyBackground = bodyBackground
      self.label = label
      self.actionForeground = actionForeground
      self.actionBackground = actionBackground
      self.copiedForeground = copiedForeground
    }
  }

  public struct TableColors: Equatable {
    public let containerBackground: AdaptiveColor
    public let headerBackground: AdaptiveColor
    public let alternateRowBackground: AdaptiveColor
    public let headerText: AdaptiveColor
    public let bodyText: AdaptiveColor

    public init(
      containerBackground: AdaptiveColor,
      headerBackground: AdaptiveColor,
      alternateRowBackground: AdaptiveColor,
      headerText: AdaptiveColor,
      bodyText: AdaptiveColor
    ) {
      self.containerBackground = containerBackground
      self.headerBackground = headerBackground
      self.alternateRowBackground = alternateRowBackground
      self.headerText = headerText
      self.bodyText = bodyText
    }
  }

  public struct DiffColors: Equatable {
    public let text: AdaptiveColor
    public let secondaryText: AdaptiveColor
    public let surface: AdaptiveColor
    public let addition: AdaptiveColor
    public let deletion: AdaptiveColor

    public init(
      text: AdaptiveColor,
      secondaryText: AdaptiveColor,
      surface: AdaptiveColor,
      addition: AdaptiveColor,
      deletion: AdaptiveColor
    ) {
      self.text = text
      self.secondaryText = secondaryText
      self.surface = surface
      self.addition = addition
      self.deletion = deletion
    }
  }

  public struct FetchColors: Equatable {
    public let errorText: AdaptiveColor
    public let actionForeground: AdaptiveColor
    public let actionBorder: AdaptiveColor

    public init(
      errorText: AdaptiveColor,
      actionForeground: AdaptiveColor,
      actionBorder: AdaptiveColor
    ) {
      self.errorText = errorText
      self.actionForeground = actionForeground
      self.actionBorder = actionBorder
    }
  }

  public struct FileIconColors: Equatable {
    public let swiftSource: AdaptiveColor
    public let code: AdaptiveColor
    public let json: AdaptiveColor
    public let markdown: AdaptiveColor
    public let stylesheet: AdaptiveColor
    public let html: AdaptiveColor
    public let image: AdaptiveColor
    public let configuration: AdaptiveColor
    public let shell: AdaptiveColor
    public let fallback: AdaptiveColor

    public init(
      swiftSource: AdaptiveColor,
      code: AdaptiveColor,
      json: AdaptiveColor,
      markdown: AdaptiveColor,
      stylesheet: AdaptiveColor,
      html: AdaptiveColor,
      image: AdaptiveColor,
      configuration: AdaptiveColor,
      shell: AdaptiveColor,
      fallback: AdaptiveColor
    ) {
      self.swiftSource = swiftSource
      self.code = code
      self.json = json
      self.markdown = markdown
      self.stylesheet = stylesheet
      self.html = html
      self.image = image
      self.configuration = configuration
      self.shell = shell
      self.fallback = fallback
    }

    public func resolve(for ext: String, colorScheme: ColorScheme) -> Color {
      let color: AdaptiveColor
      switch ext.lowercased() {
      case "swift": color = swiftSource
      case "js", "jsx", "ts", "tsx", "go", "py", "rs": color = code
      case "json": color = json
      case "md", "mdx": color = markdown
      case "css", "scss": color = stylesheet
      case "html": color = html
      case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico": color = image
      case "yml", "yaml", "toml", "lock": color = configuration
      case "sh", "bash", "zsh": color = shell
      default: color = fallback
      }
      return color.resolve(for: colorScheme)
    }
  }

  public let separator: AdaptiveColor
  public let code: CodeColors
  public let table: TableColors
  public let diff: DiffColors
  public let fetch: FetchColors
  public let fileIcon: FileIconColors

  public init(
    separator: AdaptiveColor,
    code: CodeColors,
    table: TableColors,
    diff: DiffColors,
    fetch: FetchColors,
    fileIcon: FileIconColors
  ) {
    self.separator = separator
    self.code = code
    self.table = table
    self.diff = diff
    self.fetch = fetch
    self.fileIcon = fileIcon
  }

  public static func == (lhs: MarkdownTheme, rhs: MarkdownTheme) -> Bool {
    lhs === rhs
  }

  public static let standard = MarkdownTheme(
    separator: AdaptiveColor(
      light: Color(red: 0x3C / 255, green: 0x3C / 255, blue: 0x43 / 255).opacity(0.29),
      dark: Color(red: 0x54 / 255, green: 0x54 / 255, blue: 0x58 / 255).opacity(0.6)
    ),
    code: CodeColors(
      headerBackground: AdaptiveColor(
        light: Color(red: 0xF0 / 255, green: 0xF0 / 255, blue: 0xF0 / 255),
        dark: Color(red: 0x17 / 255, green: 0x17 / 255, blue: 0x17 / 255)
      ),
      bodyBackground: AdaptiveColor(
        light: Color(red: 0xF7 / 255, green: 0xF7 / 255, blue: 0xF8 / 255),
        dark: Color(red: 0x0D / 255, green: 0x0D / 255, blue: 0x0D / 255)
      ),
      label: AdaptiveColor(
        light: Color.black.opacity(0.5),
        dark: Color.white.opacity(0.58)
      ),
      actionForeground: AdaptiveColor(
        light: Color.black.opacity(0.55),
        dark: Color.white.opacity(0.7)
      ),
      actionBackground: AdaptiveColor(
        light: Color.black.opacity(0.06),
        dark: Color.white.opacity(0.05)
      ),
      copiedForeground: AdaptiveColor(
        light: Color(red: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255),
        dark: Color(red: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255)
      )
    ),
    table: TableColors(
      containerBackground: AdaptiveColor(
        light: Color.black.opacity(0.02),
        dark: Color.white.opacity(0.025)
      ),
      headerBackground: AdaptiveColor(
        light: Color.black.opacity(0.045),
        dark: Color.white.opacity(0.055)
      ),
      alternateRowBackground: AdaptiveColor(
        light: Color.black.opacity(0.018),
        dark: Color.white.opacity(0.03)
      ),
      headerText: AdaptiveColor(
        light: Color.primary.opacity(0.96),
        dark: Color.primary.opacity(0.96)
      ),
      bodyText: AdaptiveColor(
        light: Color.primary.opacity(0.86),
        dark: Color.primary.opacity(0.86)
      )
    ),
    diff: DiffColors(
      text: AdaptiveColor(
        light: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255),
        dark: .white
      ),
      secondaryText: AdaptiveColor(
        light: Color.black.opacity(0.34),
        dark: Color.white.opacity(0.38)
      ),
      surface: AdaptiveColor(
        light: .white,
        dark: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
      ),
      addition: AdaptiveColor(
        light: Color(red: 0x16 / 255, green: 0xA3 / 255, blue: 0x4A / 255),
        dark: Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255)
      ),
      deletion: AdaptiveColor(
        light: Color(red: 0xDC / 255, green: 0x26 / 255, blue: 0x26 / 255),
        dark: Color(red: 0xF8 / 255, green: 0x71 / 255, blue: 0x71 / 255)
      )
    ),
    fetch: FetchColors(
      errorText: AdaptiveColor(light: .red, dark: .red),
      actionForeground: AdaptiveColor(light: .primary, dark: .primary),
      actionBorder: AdaptiveColor(
        light: Color.primary.opacity(0.08),
        dark: Color.primary.opacity(0.08)
      )
    ),
    fileIcon: FileIconColors(
      swiftSource: AdaptiveColor(
        light: Color(red: 0xF0 / 255, green: 0x51 / 255, blue: 0x38 / 255),
        dark: Color(red: 0xF0 / 255, green: 0x51 / 255, blue: 0x38 / 255)
      ),
      code: AdaptiveColor(
        light: Color(red: 0x60 / 255, green: 0xA5 / 255, blue: 0xFA / 255),
        dark: Color(red: 0x60 / 255, green: 0xA5 / 255, blue: 0xFA / 255)
      ),
      json: AdaptiveColor(
        light: Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255),
        dark: Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)
      ),
      markdown: AdaptiveColor(
        light: Color.primary.opacity(0.72),
        dark: Color.primary.opacity(0.72)
      ),
      stylesheet: AdaptiveColor(
        light: Color(red: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255),
        dark: Color(red: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255)
      ),
      html: AdaptiveColor(
        light: Color(red: 0xF9 / 255, green: 0x73 / 255, blue: 0x16 / 255),
        dark: Color(red: 0xF9 / 255, green: 0x73 / 255, blue: 0x16 / 255)
      ),
      image: AdaptiveColor(
        light: Color(red: 0xA7 / 255, green: 0x8B / 255, blue: 0xFA / 255),
        dark: Color(red: 0xA7 / 255, green: 0x8B / 255, blue: 0xFA / 255)
      ),
      configuration: AdaptiveColor(
        light: Color(red: 0x94 / 255, green: 0xA3 / 255, blue: 0xB8 / 255),
        dark: Color(red: 0x94 / 255, green: 0xA3 / 255, blue: 0xB8 / 255)
      ),
      shell: AdaptiveColor(
        light: Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255),
        dark: Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255)
      ),
      fallback: AdaptiveColor(
        light: Color.primary.opacity(0.68),
        dark: Color.primary.opacity(0.68)
      )
    )
  )
}
