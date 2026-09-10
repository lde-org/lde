/**
 * Raw markdown sources of the content collections, keyed by root-relative path
 * ("/src/content/docs/foo.md"). Vite inlines them at build time so the `.md`
 * routes can serve a page's source verbatim, frontmatter included.
 */
const docsSources = import.meta.glob("/src/content/docs/**/*.md", {
	query: "?raw",
	import: "default",
	eager: true,
}) as Record<string, string>;

const blogSources = import.meta.glob("/src/content/blog/**/*.{md,mdx}", {
	query: "?raw",
	import: "default",
	eager: true,
}) as Record<string, string>;

/** The parts of a content entry that raw source lookup needs. */
interface SourceEntry {
	id: string;
	filePath?: string;
}

function lookup(sources: Record<string, string>, entry: SourceEntry): string {
	if (!entry.filePath) throw new Error(`Content entry "${entry.id}" has no file path`);

	const source = sources[`/${entry.filePath}`];
	if (source === undefined) {
		throw new Error(
			`No raw source bundled for content entry "${entry.id}" (${entry.filePath})`,
		);
	}
	return source;
}

/** @param entry entry of the `docs` collection */
export function docsSource(entry: SourceEntry): string {
	return lookup(docsSources, entry);
}

/** @param entry entry of the `blog` collection */
export function blogSource(entry: SourceEntry): string {
	return lookup(blogSources, entry);
}

/** @param source raw markdown source of a page */
export function markdownResponse(source: string): Response {
	return new Response(source, {
		headers: { "Content-Type": "text/markdown; charset=utf-8" },
	});
}
