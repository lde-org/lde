import { defineMdastPlugin } from "satteri";
import { ADMONITION_TITLES, parseCalloutMarker } from "./admonitions";

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
		const paragraph = node.children[0];
		if (paragraph?.type !== "paragraph") return;
		const lead = paragraph.children[0];
		if (lead?.type !== "text") return;
		const marker = parseCalloutMarker(
			lead.value,
			paragraph.children.length > 1,
		);
		if (!marker) return;
		const type = marker.type.toUpperCase();
		const title = ADMONITION_TITLES[type];
		if (!title) return;

		if (marker.rest === null) {
			// The marker is the whole text node — drop it (and the paragraph
			// itself when it held nothing else).
			if (paragraph.children.length > 1) {
				ctx.removeChildAt(paragraph, 0);
			} else {
				ctx.removeChildAt(node, 0);
			}
		} else {
			ctx.setProperty(lead, "value", marker.rest);
		}

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
