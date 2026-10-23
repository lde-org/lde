/**
 * GitHub-style callouts (`> [!NOTE]`, `> [!WARNING]`, …).
 *
 * https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#alerts
 */

/** Display title for each supported marker type. */
export const ADMONITION_TITLES: Record<string, string> = {
	NOTE: "Note",
	TIP: "Tip",
	IMPORTANT: "Important",
	WARNING: "Warning",
	CAUTION: "Caution",
};

/**
 * Matches a bare `[!TYPE]` marker standing alone on a line (GitHub requires
 * the marker to be the first line of the blockquote, on its own). The match
 * is case-insensitive; capture 1 is the type as written.
 */
export const ADMONITION_MARKER_RE =
	/^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$/i;

/**
 * Parse the first line of a node for a `[!TYPE]` marker.
 *
 * `hasMoreSiblings` says whether the node holding the text has further inline
 * content; without a newline the marker must then be the whole node, because
 * otherwise the line continues past the marker (a plain quote on GitHub).
 *
 * `rest` is `null` when the marker is the whole node or ends at a trailing
 * newline (the marker is dropped), else the text after that newline.
 */
export function parseCalloutMarker(
	text: string,
	hasMoreSiblings: boolean,
): { type: string; rest: string | null } | null {
	const nl = text.search(/\r?\n/);
	const line = nl === -1 ? text : text.slice(0, nl);
	const m = ADMONITION_MARKER_RE.exec(line);
	if (!m) return null;
	if (nl === -1) return hasMoreSiblings ? null : { type: m[1], rest: null };
	if (nl === text.length - 1) return { type: m[1], rest: null };
	return { type: m[1], rest: text.slice(nl + 1) };
}
