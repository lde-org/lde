import type { LanguageFn } from "highlight.js";

// MoonScript is an indentation-based language that compiles to Lua. The
// grammar covers the core syntax: string interpolation (#{}), self references
// (@name / @@class), function arrows (-> / =>), comprehensions, and the
// `class`/`unless`/`switch` keywords that extend Lua's.
const moonscript: LanguageFn = (hljs) => {
	// `#{}` interpolates an expression into a string; keep it nestable by
	// allowing strings and numbers inside, like the real language.
	const INTERPOLATION = {
		className: "subst",
		begin: "#{",
		end: "}",
		contains: [
			hljs.C_NUMBER_MODE,
			hljs.APOS_STRING_MODE,
			hljs.QUOTE_STRING_MODE,
		],
	};
	return {
		name: "MoonScript",
		aliases: ["moon"],
		keywords: {
			$pattern: hljs.UNDERSCORE_IDENT_RE,
			literal: "true false nil",
			keyword:
				"and break class continue do else elseif end export extends " +
				"for from global if import in local not or return super switch " +
				"then unless until using when while with",
			built_in: "self",
		},
		contains: [
			hljs.C_LINE_COMMENT_MODE,
			{
				className: "string",
				variants: [
					{
						begin: "'",
						end: "'",
						contains: [INTERPOLATION],
					},
					{
						begin: '"',
						end: '"',
						contains: [INTERPOLATION],
					},
				],
			},
			hljs.C_NUMBER_MODE,
			{
				// `@name` / `@@class` self references.
				className: "built_in",
				begin: /@@?[A-Za-z_]\w*/,
			},
			{
				// Function/method definitions: `name = ->`, `method: =>`.
				className: "title.function",
				begin: /\b[A-Za-z_]\w*(?=\s*[:=]\s*-?>)/,
				relevance: 5,
			},
			{
				// Comprehension iterators: `for x in *items`.
				className: "operator",
				begin: /\*[A-Za-z_]\w*/,
			},
			{
				className: "operator",
				begin: /->|=>|!=|<=|>=|==|[-+*/%^<>=?]|\.\.|\|\||&&|\\/,
			},
		],
	};
};

export default moonscript;
