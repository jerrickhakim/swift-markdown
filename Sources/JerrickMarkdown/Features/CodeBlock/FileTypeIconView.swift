import SwiftUI

private func fileTypeAssetName(for ext: String) -> String {
  switch ext.lowercased() {
  case "ts": return "file-type-ts"
  case "tsx", "jsx": return "brand-react"
  case "js", "mjs": return "file-type-js"
  case "css", "scss": return "file-type-css"
  case "html", "htm": return "file-type-html"
  case "json": return "json"
  case "xml": return "file-type-xml"
  case "md", "mdx": return "markdown"
  case "swift": return "swift"
  case "sh", "bash", "zsh": return "file-dollar"
  case "png": return "file-type-png"
  case "jpg", "jpeg": return "file-type-jpg"
  case "bmp": return "file-type-bmp"
  case "gif", "webp", "heic", "heif", "ico", "tiff", "tif": return "photo"
  case "svg": return "file-type-svg"
  case "pdf": return "file-type-pdf"
  case "txt": return "file-type-txt"
  case "csv": return "file-type-csv"
  case "sql": return "file-type-sql"
  case "doc": return "file-type-doc"
  case "docx": return "file-type-docx"
  case "xls", "xlsx": return "file-type-xls"
  case "ppt", "pptx": return "file-type-ppt"
  case "mp4", "mov", "avi", "wmv", "flv", "mkv", "webm", "m4v": return "video"
  case "mp3", "wav", "ogg", "flac", "m4a", "aac", "wma", "opus", "aiff", "alac":
    return "music"
  case "zip", "tar", "gz", "rar", "7z", "bz2", "xz": return "file-type-zip"
  default: return "file"
  }
}

/// The same file-type icon used by markdown code-block headers.
public struct FileTypeIconView: View {
  public let ext: String
  public var size: CGFloat
  public var fontWeight: Font.Weight
  public let theme: MarkdownTheme

  @Environment(\.colorScheme) private var colorScheme

  public init(
    ext: String,
    size: CGFloat = 18,
    fontWeight: Font.Weight = .semibold,
    theme: MarkdownTheme = .standard
  ) {
    self.ext = ext
    self.size = size
    self.fontWeight = fontWeight
    self.theme = theme
  }

  public var body: some View {
    Image(fileTypeAssetName(for: ext), bundle: .module)
      .renderingMode(.template)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: size, height: size)
      .foregroundStyle(theme.fileIcon.resolve(for: ext, colorScheme: colorScheme))
  }
}
