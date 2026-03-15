import rss from "@astrojs/rss";
import { getCollection } from "astro:content";
import type { APIContext } from "astro";

export async function GET(context: APIContext) {
	const posts = (await getCollection("blog")).sort(
		(a, b) => b.data.published.valueOf() - a.data.published.valueOf(),
	);

	return rss({
		title: "lpm blog",
		description: "Updates and articles from the lpm project.",
		site: context.site!,
		items: posts.map((post) => ({
			title: post.data.title,
			pubDate: post.data.published,
			author: post.data.author,
			description: post.data.description,
			link: `/blog/${post.id}/`,
		})),
	});
}
