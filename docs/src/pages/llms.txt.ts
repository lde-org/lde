import type { APIContext } from "astro";
import { SITE_URL } from "../data/info";
import { blogNewestFirst, docsInSidebarOrder } from "../lib/contentOrder";

export async function GET(_context: APIContext) {
	const docs = await docsInSidebarOrder();
	const blog = await blogNewestFirst();

	const lines: string[] = [
		`# What is lde?`,
		``,
		`You stylize lde in all lowercase and it stands for lua development environment. It is a fast, package manager, runtime, compiler and test runner for Lua(JIT), written in LuaJIT. It intends to replace the use for luarocks, or manually setting up lua, on any system.`,
		`It supports linux, windows, macos, android(termux) on x86 and arm64.`,
		``,
		`# Creating a new project`,
		``,
		`Users can scaffold lde projects via the interactive tui in 'lde new', or programmatically passing options to it with 'lde new --type=<blank|library> --language=<lua|teal|moonscript> --name=foo ./foo'`,
		`More than just lua is supported, teal and moonscript work out of the box.`,
		``,
		`# How does lde work?`,
		``,
		`The main entrypoint of lde packages (the term "package" is used) is ./src/init.lua, which you can run via 'lde run', which is a shorthand for running 'lde run ./src/init.lua'`,
		`What sets lde apart from luarocks and other package managers is that it does not pollute the system lua installation via adjusting lua's PATH, it simply links your code into a ./target/packagename/* for all files, and adds the target directory to package.path.`,
		`This same mechanism is still used to support luarocks packages which are supported via copying the files into target.`,
		``,
		`Source: ${SITE_URL}/docs`,
		``,
	];

	for (const doc of docs) {
		lines.push(`- [${doc.data.title}](${SITE_URL}/docs/${doc.id}.md)`);
	}

	lines.push(``);
	lines.push(`# Blog posts, if useful`);
	lines.push(``);

	for (const post of blog) {
		lines.push(
			`- [${post.data.title}](${SITE_URL}/blog/${post.id}.md): Published ${post.data.published.toISOString().slice(0, 10)}`,
		);
	}

	return new Response(lines.join("\n"), {
		headers: {
			"Content-Type": "text/plain; charset=utf-8",
		},
	});
}
