import { getCollection } from "astro:content";
import type { APIRoute, GetStaticPaths } from "astro";
import type { CollectionEntry } from "astro:content";
import { docsSource, markdownResponse } from "../../lib/contentSource";

export const getStaticPaths: GetStaticPaths = async () => {
	const entries = await getCollection("docs");
	return entries.map((entry) => ({
		params: { slug: entry.id },
		props: { entry },
	}));
};

export const GET: APIRoute<{ entry: CollectionEntry<"docs"> }> = ({ props }) =>
	markdownResponse(docsSource(props.entry));
