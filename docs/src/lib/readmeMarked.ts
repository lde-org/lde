import { Marked, type Tokens } from "marked";
import { ADMONITION_TITLES, parseCalloutMarker } from "./admonitions";

/**
 * Marked (README) support for GitHub-style callouts (`> [!NOTE]` etc.),
 * mirroring the markup remarkGithubAdmonitions emits for the docs content.
 */

/** Marked instance that renders `> [!TYPE]` blockquotes as callouts. */
export function createReadmeMarked(): Marked {
	const marked = new Marked({ gfm: true });
	marked.use({
		renderer: {
			blockquote({ tokens }: Tokens.Blockquote) {
				const paragraph = tokens[0];
				const lead =
					paragraph?.type === "paragraph" ? paragraph.tokens[0] : undefined;
				if (paragraph?.type === "paragraph" && lead?.type === "text") {
					const marker = parseCalloutMarker(
						lead.text,
						paragraph.tokens.length > 1,
					);
					if (marker) {
						const type = marker.type.toUpperCase();
						const title = ADMONITION_TITLES[type] ?? marker.type;
						if (marker.rest === null) {
							paragraph.tokens.shift();
						} else {
							lead.text = marker.rest;
						}
						const body = this.parser.parse(
							paragraph.tokens.length === 0 ? tokens.slice(1) : tokens,
						);
						return (
							`<aside class="callout callout-${type.toLowerCase()}" data-callout="${type.toLowerCase()}">` +
							`<p class="callout-title">${title}</p>\n${body}</aside>\n`
						);
					}
				}
				return `<blockquote>\n${this.parser.parse(tokens)}\n</blockquote>`;
			},
		},
	});
	return marked;
}
