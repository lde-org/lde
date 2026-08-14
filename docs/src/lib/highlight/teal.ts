import type { LanguageFn, Mode } from "highlight.js";
import lua from "highlight.js/lib/languages/lua";

// Teal is a typed dialect of Lua: the same syntax plus `record`/`enum`/`type`
// declarations, `as`/`is` casts and type-guards, `where` constraints, and
// `continue`. Reuse the Lua grammar, then add type-annotation support:
// `local x: {string | number} | nil`, `record` fields, and parameter types.
const teal: LanguageFn = (hljs) => {
	const base = lua(hljs);
	const baseKeywords = base.keywords as {
		keyword: string;
		literal: string;
		built_in: string;
	};

	// A type reference inside an annotation (`number`, `Point`, `mod.Type`).
	const TYPE_IDENT: Mode = {
		className: "type",
		begin: /\b[A-Za-z_][A-Za-z0-9_.]*\b/,
	};

	const TYPE_OPERATOR: Mode = {
		className: "operator",
		begin: /\||->|\.\.\./,
	};

	// Table types `{ ... }`: swallow nested braces and newlines so multi-line
	// and nested types stay inside the annotation.
	const TABLE_TYPE: Mode = {
		begin: /\{/,
		end: /\}/,
		contains: ["self", TYPE_IDENT, TYPE_OPERATOR],
	};

	// `: type` annotation. Whitespace after the colon is required so method
	// calls (`obj:method()`) don't match; the annotation ends at `=`, `,`, `;`,
	// or a newline (braces keep multi-line types open). A `)` is deliberately
	// not a terminator: in `(parser: Parser)` the closing paren must end the
	// function/params scope, not be eaten by the annotation. endsWithParent
	// lets that closing paren propagate through the annotation.
	const TYPE_ANNOTATION: Mode = {
		begin: /:\s+(?=[A-Za-z_{])/,
		end: /[=\n,;]/,
		endsWithParent: true,
		contains: [TABLE_TYPE, TYPE_IDENT, TYPE_OPERATOR],
	};

	// The stock Lua function mode only allows comments inside its parameter
	// list, which would swallow `function f(a: number)`. Extend its params so
	// parameter type annotations highlight too.
	const contains = (base.contains ?? []).map((mode) => {
		if ((mode as { className?: string }).className === "function") {
			return {
				...mode,
				contains: ((mode as { contains?: Mode[] }).contains ?? []).map(
					(inner) =>
						(inner as { className?: string }).className === "params"
							? {
									...inner,
									contains: [
										...((inner as { contains?: Mode[] }).contains ??
											[]),
										TYPE_ANNOTATION,
									],
								}
							: inner,
				),
			};
		}
		return mode;
	});
	contains.push(TYPE_ANNOTATION);

	return {
		name: "Teal",
		aliases: ["tl"],
		keywords: {
			$pattern: hljs.UNDERSCORE_IDENT_RE,
			literal: baseKeywords.literal,
			keyword:
				baseKeywords.keyword +
				" record enum type as is where continue",
			// Teal-only type names; Lua's globals (string, table, …) stay in
			// built_in for value use.
			type: "any integer never number boolean",
			built_in: baseKeywords.built_in,
		},
		contains,
	};
};

export default teal;
