// @ts-check
import { defineConfig } from "astro/config";

import tailwindcss from "@tailwindcss/vite";
import preact from "@astrojs/preact";
import icon from "astro-icon";
import cloudflare from "@astrojs/cloudflare";

// https://astro.build/config
export default defineConfig({
	site: "https://lualpm.com",
	server: {
		allowedHosts: process.env.NODE_ENV !== "production" ? true : undefined,
	},
	adapter: cloudflare({
		prerenderEnvironment: "node",
	}),
	vite: {
		plugins: [tailwindcss()],
	},
	markdown: {
		shikiConfig: {
			theme: "css-variables",
		},
	},
	integrations: [preact(), icon()],
});
