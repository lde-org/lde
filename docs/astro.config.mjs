// @ts-check
import { defineConfig } from "astro/config";

import tailwindcss from "@tailwindcss/vite";
import preact from "@astrojs/preact";
import icon from "astro-icon";

// https://astro.build/config
export default defineConfig({
	site: "https://lualpm.com",
	vite: {
		plugins: [
			tailwindcss(),
			{
				name: "registry-rewrite",
				configureServer(server) {
					server.middlewares.use((req, _, next) => {
						if (req.url?.startsWith("/registry/"))
							req.url = "/registry/index.html";
						next();
					});
				},
			},
		],
	},

	markdown: {
		shikiConfig: {
			theme: "css-variables",
		},
	},

	integrations: [preact(), icon()],
});
