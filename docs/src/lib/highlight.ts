import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import ini from "highlight.js/lib/languages/ini";
import json from "highlight.js/lib/languages/json";
import lua from "highlight.js/lib/languages/lua";
import markdown from "highlight.js/lib/languages/markdown";
import yaml from "highlight.js/lib/languages/yaml";
import moonscript from "./highlight/moonscript";
import teal from "./highlight/teal";

// Languages are registered lazily on first use so the (small) per-language
// grammars only load when the file viewer is actually opened.
let registered = false;
function ensureRegistered() {
	if (registered) return;
	registered = true;
	hljs.registerLanguage("lua", lua);
	hljs.registerLanguage("teal", teal);
	hljs.registerLanguage("moonscript", moonscript);
	hljs.registerLanguage("json", json);
	hljs.registerLanguage("markdown", markdown);
	hljs.registerLanguage("yaml", yaml);
	hljs.registerLanguage("ini", ini);
	hljs.registerLanguage("bash", bash);
}

// File extension → highlight.js language name. The viewer's main audience is
// Lua, Teal, and MoonScript; the rest cover the files commonly found next to
// them in a repo.
const FILE_LANGS: Record<string, string> = {
	".lua": "lua",
	".tl": "teal",
	".moon": "moonscript",
	".json": "json",
	".jsonc": "json",
	".md": "markdown",
	".markdown": "markdown",
	".yaml": "yaml",
	".yml": "yaml",
	".toml": "ini",
	".ini": "ini",
	".cfg": "ini",
	".sh": "bash",
	".bash": "bash",
	".zsh": "bash",
};

// File extensions that can't be rendered as text (viewer shows a message).
const BINARY_RE =
	/\.(png|jpe?g|gif|webp|bmp|ico|avif|svg|woff2?|ttf|otf|eot|pdf|zip|gz|tgz|bz2|xz|zst|7z|rar|tar|exe|dll|so|dylib|o|a|lib|class|jar|wasm|mp3|mp4|webm|ogg|wav|mov|avi|flac)$/i;

/** True for files whose contents are safe to view as text. */
export function isViewableFile(path: string): boolean {
	return !BINARY_RE.test(path);
}

/** highlight.js language name for a file path, or null for plain text. */
export function langForPath(path: string): string | null {
	const ext = path.slice(path.lastIndexOf(".")).toLowerCase();
	return FILE_LANGS[ext] ?? null;
}

/**
 * Highlight file contents with the language for `path`. Returns the token
 * HTML, or null when the language is unknown or highlighting failed (callers
 * fall back to plain text).
 */
export function highlightFile(code: string, path: string): string | null {
	let lang = langForPath(path);
	if (!lang) return null;
	// A `.lua` file may actually be Teal source; correct it so annotations and
	// record/enum declarations highlight.
	if (lang === "lua" && looksLikeTeal(code)) lang = "teal";
	ensureRegistered();
	try {
		return hljs.highlight(code, { language: lang }).value;
	} catch {
		return null;
	}
}

// Teal-only syntax signals, in order of strength. The annotation pattern
// requires whitespace after the colon so method calls (`obj:method()`) can't
// match, and a type-ish name (capitalized, a built-in type, or `{`) after it.
const TEAL_STRONG = [
	/\b(?:local|global)\s+[A-Za-z_]\w*\s*=\s*(?:record|enum)\b/,
	/\btype\s+[A-Za-z_]\w*\s*=/, // `type Point = ...`
	/\b[A-Za-z_]\w*\s*:\s+(?:[A-Z][A-Za-z0-9_.]*|number|string|boolean|integer|table|any|nil|never|function|\{)/,
];
const TEAL_WEAK = [
	/\bwhere\b/,
	/\bas\s+(?:[A-Z][A-Za-z0-9_.]*|number|string|boolean|integer|table|any|nil|never)\b/,
	/\bis\s+(?:number|string|boolean|integer|table|any|nil|never)\b/,
];

/**
 * Best-effort detection of Teal in code declared as Lua (README authors often
 * fence Teal as ```lua). Comments, long brackets, and quoted strings are
 * stripped first so prose like `-- TODO: Fix` or `print("record")` can't trip
 * the heuristics. One strong signal, or any weak one (safe once comments and
 * strings are gone), means Teal.
 */
export function looksLikeTeal(code: string): boolean {
	const codeOnly = code
		.replace(/\[(=*)\[[\s\S]*?\]\1\]/g, " ") // long-bracket strings/comments
		.replace(/--[^\n]*/g, " ") // line comments
		.replace(/"(?:[^"\\\n]|\\.)*"/g, " ") // double-quoted strings
		.replace(/'(?:[^'\\\n]|\\.)*'/g, " "); // single-quoted strings

	if (TEAL_STRONG.some((re) => re.test(codeOnly))) return true;
	let weak = 0;
	for (const re of TEAL_WEAK) if (re.test(codeOnly)) weak++;
	return weak >= 1;
}

/**
 * Highlight `<pre><code>` blocks inside rendered README HTML. Blocks with a
 * known `language-*` class use that language (aliases like `tl`/`moon`
 * included); unlabelled or unknown blocks are auto-detected. Runs after
 * DOMPurify, so only sanitized markup is touched.
 */
export function highlightCodeBlocks(html: string): string {
	ensureRegistered();
	// Marked emits <pre><code class="language-x">…escaped…</code></pre> (or
	// <pre><code> for unlabelled/indented blocks). The content is HTML-escaped,
	// so the literal `</code>` cannot appear inside — safe to match lazily.
	return html.replace(
		/<pre><code(?:\s+class="([^"]*)")?>([\s\S]*?)<\/code><\/pre>/g,
		(match, cls: string | undefined, body: string) => {
			const text = decodeEntities(body);
			if (!text.trim()) return match;
			const declared = (cls?.match(/language-([\w-]+)/)?.[1] ?? "").toLowerCase();
			// README authors often fence Teal as ```lua; detect and correct.
			const lang =
				declared && hljs.getLanguage(declared)
					? declared === "lua" && looksLikeTeal(text)
						? "teal"
						: declared
					: null;
			const result = lang
				? hljs.highlight(text, { language: lang })
				: hljs.highlightAuto(text);
			const langClass = result.language ? `hljs language-${result.language}` : "hljs";
			return `<pre><code class="${langClass}">${result.value}</code></pre>`;
		},
	);
}

// Decode the entities marked escapes inside code blocks. A single pass is
// correct: `&amp;` becomes `&` after the regex has already consumed it, so
// `&amp;lt;` (escaped `&lt;`) decodes to `&lt;` without double-processing.
function decodeEntities(s: string): string {
	return s.replace(
		/&(#39|apos|quot|lt|gt|amp);/g,
		(_m, name: string) => {
			if (name === "#39" || name === "apos") return "'";
			if (name === "quot") return '"';
			if (name === "lt") return "<";
			if (name === "gt") return ">";
			return "&";
		},
	);
}
