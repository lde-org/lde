// @ts-check
import { defineConfig } from "astro/config";

import tailwindcss from "@tailwindcss/vite";
import preact from "@astrojs/preact";
import icon from "astro-icon";
import cloudflare from "@astrojs/cloudflare";

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
			],
		},
	},
	integrations: [preact(), icon()],
});
