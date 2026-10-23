import rss from "@astrojs/rss";
import type { APIContext } from "astro";
import { blogNewestFirst } from "../lib/contentOrder";

export async function GET(context: APIContext) {
	const posts = await blogNewestFirst();

	return rss({
		title: "lde blog",
		description: "Updates and articles from the lde project.",
		site: context.site!,
		items: posts.map((post) => ({
			title: post.data.title,
			pubDate: post.data.published,
			author: post.data.author,
			description: post.data.description,
			link: `/blog/${post.id}`,
			tags: post.data.tags
		})),
	});
}
