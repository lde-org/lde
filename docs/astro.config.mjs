// @ts-check
import { defineConfig } from "astro/config";

import tailwindcss from "@tailwindcss/vite";
import preact from "@astrojs/preact";
import icon from "astro-icon";
import cloudflare from "@astrojs/cloudflare";
import { satteri } from "@astrojs/markdown-satteri";
import { githubAdmonitions } from "./src/lib/githubAdmonitions.ts";

// https://astro.build/config
export default defineConfig({
	site: "https://lde.sh",
	output: "static",
	server: {
		allowedHosts: process.env.NODE_ENV !== "production" ? true : undefined,
	},
	adapter:
		process.env.NODE_ENV == "production"
			? cloudflare({
					prerenderEnvironment: "node",
				})
			: undefined,
	vite: {
		plugins: [tailwindcss()],
	},
	markdown: {
		processor: satteri({
			mdastPlugins: [githubAdmonitions],
		}),
		shikiConfig: {
			theme: "css-variables",
			transformers: [
				{
					name: "meta-filename",
					pre(node) {
						const meta = this.options.meta?.__raw?.trim();
						if (meta) {
							node.properties["data-filename"] = meta;
						}
					},
				},
				{
					// The <pre> is the horizontal scroller for long lines, so
					// wrap it in a frame that carries the language/filename
					// label: chrome attached to the scroller scrolls away.
					name: "codeblock-frame",
					pre(node) {
						const wrapper = {
							type: "element",
							tagName: "div",
							properties: { class: "codeblock" },
							children: [node],
						};
						// Astro's own transformer runs first and puts the
						// language on `dataLanguage`; `meta-filename` (listed
						// above) adds `data-filename`. Mirror both onto the
						// frame so the label renders on it.
						for (const key of ["dataLanguage", "data-filename"]) {
							const value = node.properties?.[key];
							if (value !== undefined) wrapper.properties[key] = value;
						}
						return wrapper;
					},
				},
			],
		},
	},
	integrations: [preact(), icon()],
});
