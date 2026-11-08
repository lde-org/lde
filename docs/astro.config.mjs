// @ts-check
import { defineConfig, sessionDrivers } from "astro/config";
import { fileURLToPath } from "node:url";

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
	// URLs are canonical without a trailing slash. Paired with the Cloudflare
	// asset handler's "drop-trailing-slash" (wrangler.jsonc), which serves
	// blog/index.html at /blog; build.format stays "directory" so Astro.url
	// pathnames keep their folder shape, which the layout and sidebar rely on.
	trailingSlash: "never",
	server: {
		allowedHosts: process.env.NODE_ENV !== "production" ? true : undefined,
	},
	adapter:
		process.env.NODE_ENV == "production"
			? cloudflare({
					prerenderEnvironment: "node",
				})
			: undefined,
	// Production uses the Cloudflare adapter's auto-provisioned KV driver.
	// Local dev has no adapter, so keep sessions in a local directory.
	session:
		process.env.NODE_ENV == "production"
			? undefined
			: { driver: sessionDrivers.fsLite({ base: ".astro/sessions" }) },
	vite: {
		resolve: {
			// `cloudflare:workers` only exists inside workerd. Local `astro dev`
			// has no adapter, so point it at process.env instead.
			alias:
				process.env.NODE_ENV === "production"
					? {}
					: {
							"cloudflare:workers": fileURLToPath(
								new URL("./src/lib/server/cloudflare-workers.mock.ts", import.meta.url),
							),
						},
		},
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
