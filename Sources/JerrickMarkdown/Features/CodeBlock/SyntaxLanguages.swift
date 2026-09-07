import Foundation

/// Lexical rules per language for `NativeSyntaxHighlighter`.
///
/// Most entries are a keyword set over one of the shared bases — adding a
/// C-family language should be three lines. A language absent from `table`
/// uses `generic`, which colors the constructs almost every language shares.
enum SyntaxLanguages {

  /// Rules for a fence hint, resolving the common aliases (`ts`, `py`, `sh`,
  /// …). An unrecognised language gets `generic`; an explicitly plain one gets
  /// nil, so it renders uncolored.
  static func rules(for language: String) -> SyntaxRules? {
    let name = canonical(language)
    guard name != "plaintext" else { return nil }
    return table[name] ?? generic
  }

  private static func canonical(_ language: String) -> String {
    switch language.lowercased().trimmingCharacters(in: .whitespaces) {
    case "ts", "typescript": return "typescript"
    case "tsx": return "typescript"
    case "js", "javascript", "mjs", "cjs", "node": return "javascript"
    case "jsx": return "javascript"
    case "py", "python", "python3": return "python"
    case "rb", "ruby": return "ruby"
    case "sh", "bash", "shell", "zsh", "console": return "bash"
    case "golang", "go": return "go"
    case "rs", "rust": return "rust"
    case "kt", "kts", "kotlin": return "kotlin"
    case "cs", "csharp", "c#": return "csharp"
    case "c++", "cpp", "cc", "hpp": return "cpp"
    case "objc", "objective-c", "c", "h": return "c"
    case "yml", "yaml": return "yaml"
    case "jsonc", "json5", "json": return "json"
    case "postgres", "postgresql", "mysql", "sql": return "sql"
    case "dart": return "dart"
    case "php": return "php"
    case "java": return "java"
    case "swift": return "swift"
    case "css", "scss", "sass", "less": return "css"
    case "toml": return "toml"
    case "ini", "cfg", "conf", "env", "dotenv": return "ini"
    case "dockerfile", "docker": return "dockerfile"
    case "graphql", "gql": return "graphql"
    case "html", "htm", "xhtml", "vue", "svelte": return "html"
    case "xml", "xsl", "xsd", "plist", "svg", "storyboard": return "html"
    case "md", "markdown", "mdx": return "markdown"
    case "diff", "patch": return "diff"
    case "plaintext", "plain text", "text", "txt", "": return "plaintext"
    case "lua": return "lua"
    case "scala": return "scala"
    default: return language.lowercased()
    }
  }

  /// Fallback for an unrecognised fence: comments, quoted strings and numbers
  /// are near-universal, and coloring those three reads far better than a wall
  /// of one color. No keyword set, so nothing is mis-claimed as a keyword.
  private static let generic: SyntaxRules = {
    var rules = SyntaxRules()
    rules.lineComments = ["//", "#", "--"]
    rules.blockComment = ("/*", "*/", false)
    rules.strings = [
      SyntaxStringRule("\"", "\""),
      SyntaxStringRule("'", "'"),
      SyntaxStringRule("`", "`", multiline: true),
    ]
    rules.literals = ["true", "false", "null", "nil", "None", "True", "False"]
    return rules
  }()

  // MARK: - Shared bases

  /// `//` + `/* */` comments, double and single quoted strings, capitalized
  /// identifiers as types. The starting point for most of the table.
  private static func cFamily(
    keywords: Set<String>,
    literals: Set<String> = ["true", "false", "null"],
    types: Set<String> = [],
    builtins: Set<String> = [],
    functionDecl: Set<String> = [],
    typeDecl: Set<String> = [],
    nestedComments: Bool = false,
    interpolation: (open: String, close: String)? = nil,
    identifierExtras: Set<Character> = []
  ) -> SyntaxRules {
    var rules = SyntaxRules()
    rules.lineComments = ["//"]
    rules.blockComment = ("/*", "*/", nestedComments)
    rules.strings = [
      SyntaxStringRule("\"", "\"", interpolation: interpolation),
      SyntaxStringRule("'", "'"),
    ]
    rules.keywords = keywords
    rules.literals = literals
    rules.types = types
    rules.builtins = builtins
    rules.functionDeclKeywords = functionDecl
    rules.typeDeclKeywords = typeDecl
    rules.capitalizedIdentifiersAreTypes = true
    rules.identifierExtras = identifierExtras
    return rules
  }

  // MARK: - Table

  private static let table: [String: SyntaxRules] = [
    "swift": swift,
    "typescript": typescript,
    "javascript": javascript,
    "go": go,
    "rust": rust,
    "java": java,
    "kotlin": kotlin,
    "csharp": csharp,
    "cpp": cpp,
    "c": c,
    "dart": dart,
    "scala": scala,
    "php": php,
    "python": python,
    "ruby": ruby,
    "lua": lua,
    "bash": bash,
    "json": json,
    "yaml": yaml,
    "toml": toml,
    "ini": ini,
    "sql": sql,
    "css": css,
    "graphql": graphql,
    "dockerfile": dockerfile,
    "html": markup,
    "markdown": markdown,
    "diff": diff,
  ]

  // MARK: C family

  private static let swift: SyntaxRules = {
    var rules = cFamily(
      keywords: [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch",
        "class", "continue", "convenience", "default", "defer", "deinit", "didSet", "do", "else",
        "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func", "get", "guard",
        "if", "import", "in", "indirect", "infix", "init", "inout", "internal", "is", "lazy",
        "let", "mutating", "nonisolated", "open", "operator", "override", "postfix", "precedence",
        "prefix", "private", "protocol", "public", "repeat", "required", "rethrows", "return",
        "self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw",
        "throws", "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet",
      ],
      literals: ["true", "false", "nil"],
      types: [
        "Any", "AnyObject", "Array", "Bool", "CGFloat", "Character", "Data", "Date", "Dictionary",
        "Double", "Error", "Float", "Int", "Never", "Optional", "Result", "Set", "String", "UInt",
        "URL", "Void",
      ],
      functionDecl: ["func"],
      typeDecl: ["class", "struct", "enum", "protocol", "actor", "extension", "typealias"],
      nestedComments: true,
      interpolation: ("\\(", ")")
    )
    rules.strings = [
      SyntaxStringRule(
        "\"\"\"", "\"\"\"", multiline: true, interpolation: ("\\(", ")")),
      SyntaxStringRule("\"", "\"", interpolation: ("\\(", ")")),
    ]
    rules.metaLinePrefixes = ["#if", "#else", "#endif", "#warning", "#error", "#!"]
    rules.identifierExtras = ["@", "#"]
    return rules
  }()

  private static let typescript: SyntaxRules = {
    var rules = cFamily(
      keywords: [
        "abstract", "any", "as", "async", "await", "break", "case", "catch", "class", "const",
        "constructor", "continue", "debugger", "declare", "default", "delete", "do", "else",
        "enum", "export", "extends", "finally", "for", "from", "function", "get", "if",
        "implements", "import", "in", "instanceof", "interface", "is", "keyof", "let", "namespace",
        "new", "of", "private", "protected", "public", "readonly", "return", "satisfies", "set",
        "static", "super", "switch", "this", "throw", "try", "type", "typeof", "var", "void",
        "while", "yield",
      ],
      literals: ["true", "false", "null", "undefined", "NaN"],
      types: [
        "Array", "Boolean", "Date", "Error", "Map", "Number", "Object", "Promise", "Record",
        "RegExp", "Set", "String", "Symbol", "WeakMap", "boolean", "never", "number", "string",
        "unknown",
      ],
      builtins: ["console", "document", "globalThis", "process", "window"],
      functionDecl: ["function"],
      typeDecl: ["class", "interface", "enum", "type", "namespace"],
      interpolation: ("${", "}"),
      identifierExtras: ["$"]
    )
    rules.strings = [
      SyntaxStringRule("`", "`", multiline: true, interpolation: ("${", "}")),
      SyntaxStringRule("\"", "\""),
      SyntaxStringRule("'", "'"),
    ]
    rules.quotedKeysBeforeColon = true
    return rules
  }()

  /// JS is TS minus the type-level keywords; sharing the set colors a stray
  /// `interface` in a JS block, which is harmless and keeps this one line.
  private static let javascript = typescript

  private static let go: SyntaxRules = {
    var rules = cFamily(
      keywords: [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
        "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
        "return", "select", "struct", "switch", "type", "var",
      ],
      literals: ["true", "false", "nil", "iota"],
      types: [
        "any", "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int",
        "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32",
        "uint64", "uintptr",
      ],
      builtins: [
        "append", "cap", "close", "copy", "delete", "len", "make", "new", "panic", "print",
        "println", "recover",
      ],
      functionDecl: ["func"],
      typeDecl: ["type", "struct", "interface"]
    )
    rules.strings = [
      SyntaxStringRule("`", "`", escape: nil, multiline: true),
      SyntaxStringRule("\"", "\""),
      SyntaxStringRule("'", "'"),
    ]
    return rules
  }()

  private static let rust: SyntaxRules = {
    var rules = cFamily(
      keywords: [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
        "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut",
        "pub", "ref", "return", "self", "static", "struct", "super", "trait", "type", "unsafe",
        "use", "where", "while",
      ],
      literals: ["true", "false", "None", "Some", "Ok", "Err"],
      types: [
        "String", "Vec", "Option", "Result", "Box", "Rc", "Arc", "bool", "char", "f32", "f64",
        "i8", "i16", "i32", "i64", "isize", "str", "u8", "u16", "u32", "u64", "usize",
      ],
      functionDecl: ["fn"],
      typeDecl: ["struct", "enum", "trait", "type", "impl"],
      nestedComments: true
    )
    rules.metaLinePrefixes = ["#!["]
    rules.identifierExtras = ["!"]
    return rules
  }()

  private static let java = cFamily(
    keywords: [
      "abstract", "assert", "break", "case", "catch", "class", "continue", "default", "do",
      "else", "enum", "extends", "final", "finally", "for", "if", "implements", "import",
      "instanceof", "interface", "native", "new", "package", "private", "protected", "public",
      "record", "return", "static", "super", "switch", "synchronized", "this", "throw", "throws",
      "transient", "try", "var", "void", "volatile", "while", "yield",
    ],
    literals: ["true", "false", "null"],
    types: [
      "Boolean", "Double", "Exception", "Integer", "List", "Long", "Map", "Object", "Optional",
      "Set", "String", "boolean", "byte", "char", "double", "float", "int", "long", "short",
    ],
    typeDecl: ["class", "interface", "enum", "record"],
    identifierExtras: ["@"]
  )

  private static let kotlin = cFamily(
    keywords: [
      "abstract", "actual", "annotation", "as", "break", "by", "catch", "class", "companion",
      "const", "constructor", "continue", "crossinline", "data", "do", "else", "enum", "expect",
      "external", "final", "finally", "for", "fun", "get", "if", "import", "in", "infix", "init",
      "inline", "inner", "interface", "internal", "is", "lateinit", "object", "open", "operator",
      "override", "package", "private", "protected", "public", "reified", "return", "sealed",
      "set", "super", "suspend", "this", "throw", "try", "typealias", "val", "var", "vararg",
      "when", "where", "while",
    ],
    literals: ["true", "false", "null"],
    types: [
      "Any", "Array", "Boolean", "Double", "Float", "Int", "List", "Long", "Map", "Nothing",
      "Set", "String", "Unit",
    ],
    functionDecl: ["fun"],
    typeDecl: ["class", "interface", "object", "enum", "typealias"],
    interpolation: ("${", "}"),
    identifierExtras: ["@"]
  )

  private static let csharp = cFamily(
    keywords: [
      "abstract", "as", "async", "await", "base", "break", "case", "catch", "checked", "class",
      "const", "continue", "default", "delegate", "do", "else", "enum", "event", "explicit",
      "extern", "finally", "fixed", "for", "foreach", "get", "goto", "if", "implicit", "in",
      "init", "interface", "internal", "is", "lock", "namespace", "new", "operator", "out",
      "override", "params", "private", "protected", "public", "readonly", "record", "ref",
      "return", "sealed", "set", "sizeof", "stackalloc", "static", "struct", "switch", "this",
      "throw", "try", "typeof", "unchecked", "unsafe", "using", "var", "virtual", "void",
      "volatile", "when", "where", "while", "yield",
    ],
    literals: ["true", "false", "null"],
    types: [
      "Boolean", "Console", "Dictionary", "Double", "Exception", "Int32", "Int64", "List",
      "Object", "String", "Task", "bool", "byte", "char", "decimal", "double", "float", "int",
      "long", "object", "short", "string", "uint", "ulong",
    ],
    typeDecl: ["class", "interface", "struct", "enum", "record", "namespace"],
    interpolation: ("{", "}")
  )

  private static let cpp: SyntaxRules = {
    var rules = cFamily(
      keywords: [
        "alignas", "alignof", "auto", "break", "case", "catch", "class", "concept", "const",
        "constexpr", "continue", "co_await", "co_return", "co_yield", "decltype", "default",
        "delete", "do", "else", "enum", "explicit", "export", "extern", "for", "friend", "goto",
        "if", "inline", "mutable", "namespace", "new", "noexcept", "operator", "private",
        "protected", "public", "register", "return", "sizeof", "static", "static_cast", "struct",
        "switch", "template", "this", "throw", "try", "typedef", "typename", "union", "using",
        "virtual", "volatile", "while",
      ],
      literals: ["true", "false", "nullptr", "NULL"],
      types: [
        "bool", "char", "double", "float", "int", "long", "short", "signed", "size_t",
        "std", "string", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "unsigned", "vector",
        "void", "wchar_t",
      ],
      typeDecl: ["class", "struct", "union", "enum", "namespace"]
    )
    rules.metaLinePrefixes = ["#"]
    return rules
  }()

  private static let c: SyntaxRules = {
    var rules = cFamily(
      keywords: [
        "auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern",
        "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof", "static",
        "struct", "switch", "typedef", "union", "volatile", "while",
      ],
      literals: ["NULL", "true", "false"],
      types: [
        "char", "double", "float", "int", "long", "short", "signed", "size_t", "unsigned",
        "uint8_t", "uint16_t", "uint32_t", "uint64_t", "void",
      ],
      typeDecl: ["struct", "union", "enum", "typedef"]
    )
    rules.metaLinePrefixes = ["#"]
    rules.identifierExtras = ["@"]  // Objective-C `@interface`, `@property`
    return rules
  }()

  private static let dart = cFamily(
    keywords: [
      "abstract", "as", "assert", "async", "await", "break", "case", "catch", "class", "const",
      "continue", "covariant", "default", "deferred", "do", "dynamic", "else", "enum", "export",
      "extends", "extension", "external", "factory", "final", "finally", "for", "get", "if",
      "implements", "import", "in", "is", "late", "library", "mixin", "new", "on", "operator",
      "part", "required", "rethrow", "return", "set", "show", "static", "super", "switch", "sync",
      "this", "throw", "try", "typedef", "var", "void", "while", "with", "yield",
    ],
    literals: ["true", "false", "null"],
    types: ["List", "Map", "Set", "String", "bool", "double", "int", "num"],
    typeDecl: ["class", "enum", "mixin", "extension", "typedef"],
    interpolation: ("${", "}"),
    identifierExtras: ["@"]
  )

  private static let scala = cFamily(
    keywords: [
      "abstract", "case", "catch", "class", "def", "do", "else", "extends", "final", "finally",
      "for", "forSome", "given", "if", "implicit", "import", "lazy", "match", "new", "object",
      "override", "package", "private", "protected", "return", "sealed", "super", "this", "throw",
      "trait", "try", "type", "val", "var", "while", "with", "yield",
    ],
    literals: ["true", "false", "null", "None"],
    types: ["Any", "Boolean", "Double", "Int", "List", "Long", "Map", "Option", "Seq", "String"],
    functionDecl: ["def"],
    typeDecl: ["class", "trait", "object", "type"],
    interpolation: ("${", "}")
  )

  private static let php: SyntaxRules = {
    var rules = cFamily(
      keywords: [
        "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone",
        "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "enum",
        "extends", "final", "finally", "fn", "for", "foreach", "function", "global", "if",
        "implements", "include", "instanceof", "insteadof", "interface", "list", "match",
        "namespace", "new", "or", "print", "private", "protected", "public", "readonly",
        "require", "require_once", "return", "static", "switch", "throw", "trait", "try", "use",
        "var", "while", "xor", "yield",
      ],
      literals: ["true", "false", "null", "TRUE", "FALSE", "NULL"],
      functionDecl: ["function", "fn"],
      typeDecl: ["class", "interface", "trait", "enum"],
      identifierExtras: ["$"]
    )
    rules.lineComments = ["//", "#"]
    rules.metaLinePrefixes = ["<?php", "<?=", "?>"]
    return rules
  }()

  // MARK: Markup

  private static let markup: SyntaxRules = {
    var rules = SyntaxRules()
    rules.mode = .markup
    return rules
  }()

  private static let markdown: SyntaxRules = {
    var rules = SyntaxRules()
    rules.mode = .markdown
    return rules
  }()

  private static let diff: SyntaxRules = {
    var rules = SyntaxRules()
    rules.mode = .diff
    return rules
  }()

  // MARK: Scripting

  private static let python: SyntaxRules = {
    var rules = SyntaxRules()
    rules.lineComments = ["#"]
    rules.strings = [
      SyntaxStringRule("\"\"\"", "\"\"\"", multiline: true),
      SyntaxStringRule("'''", "'''", multiline: true),
      SyntaxStringRule("\"", "\"", interpolation: ("{", "}")),
      SyntaxStringRule("'", "'", interpolation: ("{", "}")),
    ]
    rules.keywords = [
      "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
      "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is",
      "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while",
      "with", "yield",
    ]
    rules.literals = ["True", "False", "None"]
    rules.types = ["bool", "bytes", "dict", "float", "int", "list", "set", "str", "tuple"]
    rules.builtins = [
      "abs", "all", "any", "enumerate", "isinstance", "len", "max", "min", "open", "print",
      "range", "sorted", "sum", "super", "type", "zip",
    ]
    rules.functionDeclKeywords = ["def"]
    rules.typeDeclKeywords = ["class"]
    rules.metaLinePrefixes = ["#!"]
    rules.identifierExtras = ["@"]
    return rules
  }()

  private static let ruby: SyntaxRules = {
    var rules = SyntaxRules()
    rules.lineComments = ["#"]
    rules.strings = [
      SyntaxStringRule("\"", "\"", interpolation: ("#{", "}")),
      SyntaxStringRule("'", "'"),
    ]
    rules.keywords = [
      "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif",
      "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue",
      "retry", "return", "self", "super", "then", "undef", "unless", "until", "when", "while",
      "yield",
    ]
    rules.literals = ["true", "false", "nil"]
    rules.builtins = ["attr_accessor", "attr_reader", "attr_writer", "puts", "require", "require_relative"]
    rules.functionDeclKeywords = ["def"]
    rules.typeDeclKeywords = ["class", "module"]
    rules.capitalizedIdentifiersAreTypes = true
    rules.identifierExtras = ["@", "$", "?", "!"]
    rules.metaLinePrefixes = ["#!"]
    return rules
  }()

  private static let lua: SyntaxRules = {
    var rules = SyntaxRules()
    rules.lineComments = ["--"]
    rules.blockComment = ("--[[", "]]", false)
    rules.strings = [
      SyntaxStringRule("[[", "]]", escape: nil, multiline: true),
      SyntaxStringRule("\"", "\""),
      SyntaxStringRule("'", "'"),
    ]
    rules.keywords = [
      "and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in",
      "local", "not", "or", "repeat", "return", "then", "until", "while",
    ]
    rules.literals = ["true", "false", "nil"]
    rules.builtins = ["ipairs", "pairs", "print", "require", "setmetatable", "tonumber", "tostring"]
    rules.functionDeclKeywords = ["function"]
    return rules
  }()

  private static let bash: SyntaxRules = {
    var rules = SyntaxRules()
    rules.lineComments = ["#"]
    rules.strings = [
      SyntaxStringRule("\"", "\"", interpolation: ("${", "}")),
      SyntaxStringRule("'", "'", escape: nil),
    ]
    rules.keywords = [
      "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "local",
      "return", "select", "then", "until", "while",
    ]
    rules.builtins = [
      "cat", "cd", "chmod", "cp", "curl", "echo", "eval", "exec", "exit", "export", "git", "grep",
      "kill", "ls", "mkdir", "mv", "printf", "read", "rm", "sed", "set", "source", "sudo", "tar",
      "test", "touch", "unset", "wget",
    ]
    rules.metaLinePrefixes = ["#!"]
    rules.identifierExtras = ["$", "-"]
    return rules
  }()

  // MARK: Data + query

  private static let json: SyntaxRules = {
    var rules = SyntaxRules()
    rules.strings = [SyntaxStringRule("\"", "\"")]
    rules.literals = ["true", "false", "null"]
    rules.quotedKeysBeforeColon = true
    // JSON5/JSONC in practice; harmless for strict JSON.
    rules.lineComments = ["//"]
    rules.blockComment = ("/*", "*/", false)
    return rules
  }()

  private static let yaml: SyntaxRules = {
    var rules = SyntaxRules()
    rules.lineComments = ["#"]
    rules.strings = [
      SyntaxStringRule("\"", "\""),
      SyntaxStringRule("'", "'", escape: nil),
    ]
    rules.literals = ["true", "false", "null", "yes", "no", "on", "off", "~"]
    rules.bareKeysBeforeColon = true
    rules.quotedKeysBeforeColon = true
    rules.identifierExtras = ["-", "."]
    return rules
  }()

  private static let toml: SyntaxRules = {
    var rules = SyntaxRules()
    rules.lineComments = ["#"]
    rules.strings = [
      SyntaxStringRule("\"\"\"", "\"\"\"", multiline: true),
      SyntaxStringRule("\"", "\""),
      SyntaxStringRule("'", "'", escape: nil),
    ]
    rules.literals = ["true", "false"]
    rules.bareKeysBeforeColon = true
    rules.identifierExtras = ["-", "."]
    return rules
  }()

  private static let ini: SyntaxRules = {
    var rules = SyntaxRules()
    rules.lineComments = ["#", ";"]
    rules.strings = [SyntaxStringRule("\"", "\""), SyntaxStringRule("'", "'", escape: nil)]
    rules.literals = ["true", "false"]
    rules.identifierExtras = ["-", "."]
    return rules
  }()

  private static let sql: SyntaxRules = {
    var rules = SyntaxRules()
    rules.lineComments = ["--"]
    rules.blockComment = ("/*", "*/", false)
    rules.strings = [
      SyntaxStringRule("'", "'", escape: nil),
      SyntaxStringRule("\"", "\"", escape: nil),
    ]
    rules.keywords = [
      "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "cast",
      "column", "commit", "constraint", "create", "cross", "database", "default", "delete",
      "desc", "distinct", "drop", "else", "end", "except", "exists", "foreign", "from", "full",
      "group", "having", "if", "in", "index", "inner", "insert", "intersect", "interval", "into",
      "is", "join", "key", "left", "like", "limit", "not", "offset", "on", "or", "order", "outer",
      "primary", "references", "returning", "right", "rollback", "select", "set", "table", "then",
      "transaction", "union", "unique", "update", "using", "values", "view", "when", "where",
      "with",
    ]
    rules.literals = ["true", "false", "null"]
    rules.builtins = [
      "avg", "coalesce", "count", "date_trunc", "max", "min", "now", "nullif", "sum",
    ]
    rules.caseInsensitiveKeywords = true
    return rules
  }()

  private static let css: SyntaxRules = {
    var rules = SyntaxRules()
    rules.blockComment = ("/*", "*/", false)
    rules.lineComments = ["//"]  // SCSS/LESS
    rules.strings = [SyntaxStringRule("\"", "\""), SyntaxStringRule("'", "'")]
    rules.keywords = [
      "and", "from", "important", "not", "only", "to",
    ]
    rules.builtins = [
      "calc", "clamp", "hsl", "hsla", "linear-gradient", "max", "min", "rgb", "rgba", "url", "var",
    ]
    rules.bareKeysBeforeColon = true
    rules.identifierExtras = ["-", "@", "$", "#", "."]
    return rules
  }()

  private static let graphql: SyntaxRules = {
    var rules = SyntaxRules()
    rules.lineComments = ["#"]
    rules.strings = [
      SyntaxStringRule("\"\"\"", "\"\"\"", multiline: true), SyntaxStringRule("\"", "\""),
    ]
    rules.keywords = [
      "directive", "enum", "extend", "fragment", "implements", "input", "interface", "mutation",
      "on", "query", "scalar", "schema", "subscription", "type", "union",
    ]
    rules.literals = ["true", "false", "null"]
    rules.types = ["Boolean", "Float", "ID", "Int", "String"]
    rules.typeDeclKeywords = ["type", "input", "interface", "enum", "union", "scalar"]
    rules.functionDeclKeywords = ["query", "mutation", "subscription", "fragment"]
    rules.bareKeysBeforeColon = true
    rules.identifierExtras = ["$", "@"]
    return rules
  }()

  private static let dockerfile: SyntaxRules = {
    var rules = SyntaxRules()
    rules.lineComments = ["#"]
    rules.strings = [SyntaxStringRule("\"", "\""), SyntaxStringRule("'", "'")]
    rules.keywords = [
      "ADD", "ARG", "AS", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE", "FROM", "HEALTHCHECK",
      "LABEL", "MAINTAINER", "ONBUILD", "RUN", "SHELL", "STOPSIGNAL", "USER", "VOLUME", "WORKDIR",
    ]
    rules.identifierExtras = ["$", "-"]
    return rules
  }()
}
