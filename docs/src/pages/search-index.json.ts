import { getCollection } from "astro:content";
import type { APIContext } from "astro";

function stripMarkdown(text: string): string {
	return text
		.replace(/```[\s\S]*?```/g, "")
		.replace(/`[^`]+`/g, "")
		.replace(/#{1,6}\s/g, "")
		.replace(/\*\*?|__?/g, "")
		.replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
		.replace(/\n+/g, " ")
		.trim();
}

export async function GET(_context: APIContext) {
	const [docs, posts] = await Promise.all([
		getCollection("docs"),
		getCollection("blog"),
	]);

	const index = [
		...docs.map((doc) => ({
			title: doc.data.title,
			url: `/docs/${doc.id}`,
			type: "doc",
			body: stripMarkdown(doc.body ?? ""),
		})),
		...posts.map((post) => ({
			title: post.data.title,
			url: `/blog/${post.id}`,
			type: "blog",
			body: stripMarkdown(post.body ?? ""),
		})),
	];

	return new Response(JSON.stringify(index), {
		headers: { "Content-Type": "application/json" },
	});
}
