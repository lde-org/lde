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
