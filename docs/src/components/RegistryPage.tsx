import { type ComponentChildren } from "preact";
import { useState, useEffect } from "preact/hooks";
import Registry from "./Registry.tsx";
import PackageDetail from "./PackageDetail.tsx";

function getPackageName(): string | null {
	const match = window.location.pathname.match(/^\/registry\/([^/]+)\/?$/);
	return match ? match[1] : null;
}

export default function RegistryPage() {
	const [packageName, setPackageName] = useState<string | null>(null);

	useEffect(() => {
		setPackageName(getPackageName());
	}, []);

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
		<div class="px-4 md:px-6 py-12 max-w-5xl mx-auto w-full">
			<div class="mb-10">
				<h1 class="text-3xl font-bold mb-3">Registry</h1>
				<p class="text-black/60 dark:text-white/60">
					Browse community packages. Install any package with{" "}
					<code class="text-sm font-mono px-1.5 py-0.5 rounded bg-black/5 dark:bg-white/10">
						lde add &lt;name&gt;
					</code>
					.
				</p>
			</div>
			<Note>
				Looking for LuaRocks packages? Search for them at{" "}
				<a
					href="https://luarocks.org/"
					target="_blank"
					rel="noopener noreferrer"
					class="text-blue-500 hover:text-blue-400 underline underline-offset-2"
				>
					luarocks.org
				</a>{" "}
				and install with{" "}
				<code class="text-sm font-mono px-1.5 py-0.5 rounded bg-black/5 dark:bg-white/10">
					lde add rocks:packagename
				</code>
				.
			</Note>
			<Registry />
		</div>
	);
}

function Note({ children }: { children: ComponentChildren }) {
	return (
		<div class="mb-8 flex gap-3 rounded-xl border border-blue-200 dark:border-blue-900 bg-blue-50 dark:bg-blue-950/40 px-4 py-3 text-sm text-blue-900 dark:text-blue-200">
			<span class="mt-0.5 shrink-0">💡</span>
			<p>{children}</p>
		</div>
	);
}
