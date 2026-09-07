import Foundation

/// Presentation helpers for code blocks.
enum CodeBlockHelpers {

    /// Keep fence normalization package-local. The original renderer used the
    /// host application's `FileTypes` utility, which is not part of this Swift
    /// package and made a clean remote build fail.
    static func normalizedLanguage(_ language: String) -> String {
        let lower = language.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lower {
        case "ts": return "typescript"
        case "tsx": return "tsx"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "jsx"
        case "py", "pyw", "pyi": return "python"
        case "rb", "gemspec", "rake": return "ruby"
        case "sh", "bash", "zsh", "ksh": return "bash"
        case "yml", "yaml": return "yaml"
        case "md", "markdown": return "markdown"
        case "json5", "jsonc": return "json"
        case "cxx", "cc", "hpp", "hxx": return "cpp"
        case "cs": return "csharp"
        case "fs", "fsx", "fsi": return "fsharp"
        case "vb": return "vbnet"
        case "kt", "kts": return "kotlin"
        case "rs": return "rust"
        case "htm", "xhtml": return "html"
        case "scss", "sass", "less": return "css"
        case "xsl", "xsd": return "xml"
        case "gql": return "graphql"
        case "mk": return "makefile"
        case "cfg": return "ini"
        default: return lower.isEmpty ? "plain text" : lower
        }
    }

    /// Maps a canonical language name (as returned by `normalizedLanguage`) to the file
    /// extension used by `FileTypeIconView`, so a code block can show the same icon
    /// the file tree uses. Returns nil for `plain text` / unknown languages.
    static func fileExtension(forLanguage language: String) -> String? {
        switch language.lowercased() {
        case "typescript": return "ts"
        case "tsx": return "tsx"
        case "javascript": return "js"
        case "jsx": return "jsx"
        case "python": return "py"
        case "ruby": return "rb"
        case "bash", "shell": return "sh"
        case "yaml": return "yml"
        case "markdown": return "md"
        case "json": return "json"
        case "cpp": return "cpp"
        case "c": return "c"
        case "csharp": return "cs"
        case "fsharp": return "fs"
        case "kotlin": return "kt"
        case "scala": return "scala"
        case "go": return "go"
        case "rust": return "rs"
        case "swift": return "swift"
        case "java": return "java"
        case "sql": return "sql"
        case "html": return "html"
        case "css": return "css"
        case "xml": return "xml"
        case "php": return "php"
        case "dart": return "dart"
        case "perl": return "pl"
        case "graphql": return "graphql"
        case "dockerfile": return "dockerfile"
        case "makefile": return "mk"
        case "toml": return "toml"
        case "ini": return "ini"
        case "env": return "env"
        case "plain text", "": return nil
        // Fence hints that are already extensions pass straight through.
        default: return language.lowercased()
        }
    }
}
