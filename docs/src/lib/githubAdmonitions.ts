import { defineMdastPlugin, type MdastVisitorContext } from "satteri";
import type { Blockquote, Paragraph } from "mdast";
import { ADMONITION_MARKER_RE, ADMONITION_TITLES } from "./admonitions";

/**
 * Sätteri mdast plugin: turn GitHub-style `> [!NOTE]` blockquotes into callout
 * `<aside>` elements (`.callout.callout-note` etc.).
 *
 * The marker must be the first line of the blockquote, on its own — exactly
 * like GitHub. `> [!NOTE] trailing text` and ordinary quotes pass through.
 * When content follows the marker on the next `>` line (the common case), it
 * stays in the same paragraph and only the marker text is stripped.
 *
 * The blockquote becomes an `<aside>` via `data.hName`, which the Sätteri
 * mdast→hast conversion honors.
 */
export const githubAdmonitions = defineMdastPlugin({
	name: "github-admonitions",
	blockquote(node, ctx) {
		const first = node.children[0];
		if (first?.type !== "paragraph") return;
		const raw = matchMarker(first);
		if (!raw) return;
		const type = raw.toUpperCase();
		const title = ADMONITION_TITLES[type];
		if (!title) return;

		stripMarker(first, ctx, node);
		ctx.setProperty(node, "data", {
			...node.data,
			hName: "aside",
			hProperties: {
				className: ["callout", `callout-${type.toLowerCase()}`],
				"data-callout": type.toLowerCase(),
			},
		});
		ctx.prependChild(node, {
			type: "paragraph",
			data: { hProperties: { className: ["callout-title"] } },
			children: [{ type: "text", value: title }],
		});
	},
});

/** The marker type if the paragraph's first line is a bare `[!TYPE]` marker. */
function matchMarker(paragraph: Paragraph): string | null {
	const first = paragraph.children[0];
	if (first?.type !== "text") return null;
	const nl = first.value.search(/\r?\n/);
	const line = nl === -1 ? first.value : first.value.slice(0, nl);
	const m = ADMONITION_MARKER_RE.exec(line);
	if (!m) return null;
	// Without a newline the marker must be the whole paragraph; more children
	// means the line continues past the marker (GitHub treats that as a
	// plain quote).
	if (nl === -1 && paragraph.children.length > 1) return null;
	return m[1];
}

/** Remove the marker line from the paragraph's leading text node. */
function stripMarker(
	paragraph: Paragraph,
	ctx: MdastVisitorContext,
	blockquote: Readonly<Blockquote>,
) {
	const first = paragraph.children[0];
	if (first?.type !== "text") return;
	const nl = first.value.search(/\r?\n/);
	if (nl === -1 || nl === first.value.length - 1) {
		// The marker is the whole text node — drop it (and the paragraph
		// itself when it held nothing else).
		if (paragraph.children.length > 1) {
			ctx.removeChildAt(paragraph, 0);
		} else {
			ctx.removeChildAt(blockquote, 0);
		}
	} else {
		ctx.setProperty(first, "value", first.value.slice(nl + 1));
	}
}
