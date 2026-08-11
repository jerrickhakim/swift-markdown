import Foundation

/// Guesses the programming language from code content when markdown doesn't specify it.
/// Used when code blocks use plain ``` without a language identifier.
enum CodeBlockHelpers {

    /// Returns the best-guess language for a code block.
    /// - Parameters:
    ///   - code: The raw code content
    ///   - explicitLanguage: Language from markdown fence (e.g. ```typescript)
    /// - Returns: Normalized language string for display/highlighting
    static func guessFileType(code: String, explicitLanguage: String?) -> String {
        if let lang = explicitLanguage, !lang.trimmingCharacters(in: .whitespaces).isEmpty {
            return normalizedLanguage(lang)
        }
        return guessFromContent(code)
    }

    /// Keep fence normalization package-local. The original renderer used the
    /// host application's `FileTypes` utility, which is not part of this Swift
    /// package and made a clean remote build fail.
    private static func normalizedLanguage(_ language: String) -> String {
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

    /// Maps a canonical language name (as returned by `guessFileType`) to the file
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

    /// Infer language from code content using heuristics (shebangs, imports, keywords)
    private static func guessFromContent(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLines = String(trimmed.prefix(800))
        let lower = firstLines.lowercased()

        // Shebang
        if trimmed.hasPrefix("#!") {
            if lower.contains("python") || lower.contains("python3") { return "python" }
            if lower.contains("node") || lower.contains("nodejs") { return "javascript" }
            if lower.contains("ruby") { return "ruby" }
            if lower.contains("bash") || lower.contains("sh") { return "bash" }
            if lower.contains("perl") { return "perl" }
        }

        // Imports / requires
        if firstLines.contains("import ") && (firstLines.contains(" from ") || firstLines.contains("require(")) {
            if firstLines.contains("React") || firstLines.contains("vue") || firstLines.contains("angular") {
                return "typescript"
            }
            return "javascript"
        }
        if firstLines.contains("import ") && firstLines.contains(";") && !firstLines.contains(" from ") {
            return "java"
        }
        if firstLines.contains("package ") && firstLines.contains("import ") {
            return "go"
        }
        if firstLines.contains("use ") && firstLines.contains(";") && (firstLines.contains("std::") || firstLines.contains("namespace")) {
            return "cpp"
        }
        if firstLines.contains("using ") && firstLines.contains(";") && firstLines.contains("namespace") {
            return "csharp"
        }
        if firstLines.contains("import ") && !firstLines.contains(" from ") && !firstLines.contains(";") {
            if firstLines.contains("swift") || firstLines.contains("Foundation") { return "swift" }
            if firstLines.contains("dart") { return "dart" }
        }
        if firstLines.contains("require ") || firstLines.contains("require(") {
            return "javascript"
        }

        // Keywords
        if (lower.contains("def ") || lower.contains("class ") && lower.contains(":")) && lower.contains("import ") == false {
            if lower.contains("self") || lower.contains("__init__") || lower.contains("lambda ") {
                return "python"
            }
        }
        if lower.contains("func ") && lower.contains("{") {
            return "swift"
        }
        if lower.contains("fn ") && lower.contains("->") {
            return "rust"
        }
        if lower.contains("func ") && lower.contains(")") && !lower.contains("->") {
            return "go"
        }
        if lower.contains("interface ") || lower.contains("type ") && lower.contains("=") && lower.contains("{") {
            return "typescript"
        }
        if lower.contains("const ") || lower.contains("let ") || lower.contains("var ") {
            if lower.contains("=>") || lower.contains("async ") || lower.contains("await ") {
                return "javascript"
            }
        }
        if lower.contains("<?php") || lower.contains("<?=") {
            return "php"
        }
        if trimmed.hasPrefix("<") && (lower.contains("<html") || lower.contains("<div") || lower.contains("<script")) {
            return "html"
        }
        if lower.contains("select ") && lower.contains("from ") {
            return "sql"
        }
        if lower.contains("insert into ") || lower.contains("create table") {
            return "sql"
        }
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            if lower.contains("\"") && (lower.contains(":") || lower.contains(",")) {
                return "json"
            }
        }
        if lower.contains("---") && (lower.contains("key:") || lower.contains("value:")) {
            return "yaml"
        }
        if lower.contains("[") && lower.contains("]") && lower.contains("=") && !lower.contains("function") {
            return "ini"
        }
        if lower.contains("from ") && lower.contains("run ") && lower.contains("copy ") {
            return "dockerfile"
        }

        return "plain text"
    }
}
