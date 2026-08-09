import { useState, useEffect } from "preact/hooks";
import Registry from "./Registry.tsx";
import PackageDetail from "./PackageDetail.tsx";

function getPackageName(): string | null {
	const match = window.location.pathname.match(/^\/registry\/([^/]+)\/?$/);
	const name = match ? match[1] : null;
	return name && name !== "publish" ? name : null;
}

const DOC_LINKS = [
	{
		label: "How it works",
		href: "/docs/package-manager/dependencies/registry",
	},
	{
		label: "Publishing guide",
		href: "/docs/package-manager/guides/publishing-to-lde",
	},
	{
		label: "Custom registries",
		href: "/docs/package-manager/guides/custom-registry",
	},
];

const COMPARISON = [
	"You get to choose your own host. The registry is just a convenience to find your package.",
	"No server means no data is logged, and security is delegated to GitHub.",
	"You go straight to the sauce instead of relying on a slow middleman.",
	"The simplicity of lde projects is not well supported by LuaRocks' explicit per-file listings.",
];

export default function RegistryPage({ name }: { name?: string }) {
	// The Astro route resolves the slug, so the server-rendered view already
	// matches the URL — no list→detail layout swap when the page hydrates.
	const [packageName, setPackageName] = useState<string | null>(name ?? null);

	useEffect(() => {
		if (!name) {
			setPackageName(getPackageName());
		}
	}, [name]);

	if (packageName) {
		return (
			<div class="px-4 md:px-6 py-12 max-w-3xl mx-auto w-full">
				<a
					href="/registry/"
					class="inline-flex items-center gap-1.5 text-sm text-black/50 dark:text-white/50 hover:text-blue-500 transition-colors mb-8"
				>
					<svg
						xmlns="http://www.w3.org/2000/svg"
						class="size-3.5"
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="2.5"
						stroke-linecap="round"
						stroke-linejoin="round"
					>
						<polyline points="15 18 9 12 15 6" />
					</svg>
					Registry
				</a>
				<PackageDetail name={packageName} />
			</div>
		);
	}

	return (
		<div class="px-4 md:px-6 pt-32 pb-16 max-w-5xl mx-auto w-full">
			{/* Hero */}
			<div class="text-center mb-10">
				<h1 class="text-4xl md:text-5xl font-bold tracking-tight">
					The official lde registry
				</h1>
				<p class="mt-4 text-black/60 dark:text-white/55 max-w-xl mx-auto leading-relaxed">
					Publish and install packages for easy access.
				</p>
				<div class="mt-6 flex flex-wrap items-center justify-center gap-x-6 gap-y-3">
					{DOC_LINKS.map((link) => (
						<a
							key={link.href}
							href={link.href}
							class="inline-flex items-center gap-1.5 text-sm font-medium text-blue-500 hover:text-blue-400 transition-colors"
						>
							{link.label}
							<svg
								xmlns="http://www.w3.org/2000/svg"
								class="size-3.5"
								viewBox="0 0 24 24"
								fill="none"
								stroke="currentColor"
								stroke-width="2"
								stroke-linecap="round"
								stroke-linejoin="round"
							>
								<path d="M5 12h14" />
								<path d="m12 5 7 7-7 7" />
							</svg>
						</a>
					))}
				</div>
			</div>

			<Registry />

			{/* Comparison */}
			<section class="mt-16 border-t border-black/8 dark:border-white/8 pt-12">
				<div class="text-center mb-8">
					<h2 class="text-2xl font-bold tracking-tight">
						Why another registry?
					</h2>
					<p class="mt-2 text-black/50 dark:text-white/40">
						In a nutshell...
					</p>
				</div>
				<div class="max-w-2xl mx-auto flex flex-col divide-y divide-black/8 dark:divide-white/8 border border-black/10 dark:border-white/10">
					{COMPARISON.map((point) => (
						<div class="flex items-start gap-3 px-4 py-4">
							<svg
								xmlns="http://www.w3.org/2000/svg"
								class="size-4 mt-0.5 shrink-0 text-blue-500"
								viewBox="0 0 24 24"
								fill="none"
								stroke="currentColor"
								stroke-width="2.5"
								stroke-linecap="round"
								stroke-linejoin="round"
							>
								<polyline points="20 6 9 17 4 12" />
							</svg>
							<p class="text-sm text-black/70 dark:text-white/70 leading-relaxed">
								{point}
							</p>
						</div>
					))}
				</div>
			</section>
		</div>
	);
}
