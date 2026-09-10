import { getCollection } from "astro:content";
import type { APIRoute, GetStaticPaths } from "astro";
import type { CollectionEntry } from "astro:content";
import { blogSource, markdownResponse } from "../../lib/contentSource";

export const getStaticPaths: GetStaticPaths = async () => {
	const posts = await getCollection("blog");
	return posts.map((post) => ({
		params: { slug: post.id },
		props: { post },
	}));
};

export const GET: APIRoute<{ post: CollectionEntry<"blog"> }> = ({ props }) =>
	markdownResponse(blogSource(props.post));
