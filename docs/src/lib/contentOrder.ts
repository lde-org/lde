import { getCollection, type CollectionEntry } from "astro:content";

/**
 * Docs entries in sidebar order: by containing directory, then by the
 * frontmatter `order` field.
 */
export async function docsInSidebarOrder(): Promise<CollectionEntry<"docs">[]> {
	return (await getCollection("docs")).sort((a, b) => {
		const aDir = a.id.split("/").slice(0, -1).join("/");
		const bDir = b.id.split("/").slice(0, -1).join("/");
		if (aDir !== bDir) return aDir.localeCompare(bDir);
		return a.data.order - b.data.order;
	});
}

/** Blog entries, newest `published` date first. */
export async function blogNewestFirst(): Promise<CollectionEntry<"blog">[]> {
	return (await getCollection("blog")).sort(
		(a, b) => b.data.published.valueOf() - a.data.published.valueOf(),
	);
}
