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
						lpm add &lt;name&gt;
					</code>
					.
				</p>
			</div>
			<Registry />
		</div>
	);
}
