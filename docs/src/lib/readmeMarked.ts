import { Marked, type Tokens } from "marked";
import { ADMONITION_MARKER_RE, ADMONITION_TITLES } from "./admonitions";

/**
 * Marked (README) support for GitHub-style callouts (`> [!NOTE]` etc.),
 * mirroring the markup remarkGithubAdmonitions emits for the docs content.
 */

/** Marker type if the paragraph's first line is a bare `[!TYPE]` marker. */
function matchCalloutMarker(paragraph: Tokens.Paragraph): string | null {
	const first = paragraph.tokens[0];
	if (!first || first.type !== "text") return null;
	const nl = first.text.search(/\r?\n/);
	const line = nl === -1 ? first.text : first.text.slice(0, nl);
	const m = ADMONITION_MARKER_RE.exec(line);
	if (!m) return null;
	// Without a newline the marker must be the whole paragraph; more tokens
	// means the line continues past the marker (a plain quote on GitHub).
	if (nl === -1 && paragraph.tokens.length > 1) return null;
	return m[1];
}

/** Remove the marker line from the paragraph's leading inline text token. */
function stripCalloutMarker(paragraph: Tokens.Paragraph) {
	const first = paragraph.tokens[0];
	if (!first || first.type !== "text") return;
	const nl = first.text.search(/\r?\n/);
	if (nl === -1 || nl === first.text.length - 1) {
		paragraph.tokens.shift();
	} else {
		first.text = first.text.slice(nl + 1);
	}
}

/** Marked instance that renders `> [!TYPE]` blockquotes as callouts. */
export function createReadmeMarked(): Marked {
	const marked = new Marked({ gfm: true });
	marked.use({
		renderer: {
			blockquote({ tokens }: Tokens.Blockquote) {
				const first = tokens[0];
				const raw =
					first?.type === "paragraph" ? matchCalloutMarker(first) : null;
				if (!raw) {
					return `<blockquote>\n${this.parser.parse(tokens)}\n</blockquote>`;
				}
				const type = raw.toUpperCase();
				const title = ADMONITION_TITLES[type] ?? raw;
				stripCalloutMarker(first);
				const body = this.parser.parse(
					first.tokens.length === 0 ? tokens.slice(1) : tokens,
				);
				return (
					`<aside class="callout callout-${type.toLowerCase()}" data-callout="${type.toLowerCase()}">` +
					`<p class="callout-title">${title}</p>\n${body}</aside>\n`
				);
			},
		},
	});
	return marked;
}
