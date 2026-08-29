-- Re-export of the shared syntax highlighter (moved into the ansi package so
-- both the REPL/error snippets and lde-core diagnostics can use it).
return require("ansi.highlight")
