import { useState, useEffect } from "preact/hooks";
import { CopyButton } from "./CopyButton";

interface PackageSummary {
	name: string;
	description: string | null;
	authors: string[];
	latest: string | null;
	git: string;
}

interface Portfile {
	name: string;
	description?: string;
	license?: string;
	authors?: string[];
	git: string;
	branch?: string;
	versions: Record<string, string>;
	dependencies?: Record<string, string>;
}

const CACHE_TTL = 5 * 60 * 1000; // 5 minutes

function portfileUrl(name: string) {
	return `https://raw.githubusercontent.com/codebycruz/lpm-registry/master/packages/${name}.json`;
}

function loadCached(name: string): Portfile | null {
	try {
		const raw = localStorage.getItem(`lpm-portfile:${name}`);
		if (!raw) return null;
		const { data, ts } = JSON.parse(raw);
		if (Date.now() - ts > CACHE_TTL) return null;
		return data;
	} catch {
		return null;
	}
}

function saveCache(name: string, data: Portfile) {
	try {
		localStorage.setItem(`lpm-portfile:${name}`, JSON.stringify({ data, ts: Date.now() }));
	} catch {}
}

function sortedVersions(versions: Record<string, string>) {
	return Object.entries(versions).sort(([a], [b]) => {
		const parse = (v: string) => v.split(".").map(Number);
		const [ma, mia, pa] = parse(a);
		const [mb, mib, pb] = parse(b);
		if (ma !== mb) return mb - ma;
		if (mia !== mib) return mib - mia;
		return pb - pa;
	});
}

export default function PackageDetail({ pkg }: { pkg: PackageSummary }) {
	const [portfile, setPortfile] = useState<Portfile | null>(() => loadCached(pkg.name));
	const installCmd = `lpm add ${pkg.name}`;
	const repoName = pkg.git.replace(/\.git$/, "").replace(/\/$/, "").split("/").slice(-2).join("/");

	useEffect(() => {
		if (portfile) return; // already have fresh cached data
		fetch(portfileUrl(pkg.name))
			.then((r) => r.ok ? r.json() : null)
			.then((data: Portfile | null) => {
				if (data) {
					saveCache(pkg.name, data);
					setPortfile(data);
				}
			})
			.catch(() => {});
	}, [pkg.name]);

	const versions = portfile ? sortedVersions(portfile.versions) : null;
	const license = portfile?.license ?? null;
	const deps = portfile?.dependencies ? Object.entries(portfile.dependencies) : null;

	return (
		<div class="flex flex-col gap-8">
			{/* Header */}
			<div class="flex flex-col gap-3">
				<div class="flex items-center gap-3 flex-wrap">
					<h1 class="text-3xl font-bold">{pkg.name}</h1>
					{pkg.latest && (
						<span class="text-sm font-mono px-2 py-1 rounded-lg bg-blue-500/10 text-blue-500 border border-blue-500/20">
							v{pkg.latest}
						</span>
					)}
				</div>

				{pkg.description && (
					<p class="text-black/60 dark:text-white/60 leading-relaxed">
						{pkg.description}
					</p>
				)}

				<div class="flex flex-wrap gap-x-4 gap-y-1 text-sm text-black/40 dark:text-white/40">
					{pkg.authors && pkg.authors.length > 0 && (
						<span>by {pkg.authors.join(", ")}</span>
					)}
					{license && (
						<span class="px-1.5 py-0.5 rounded bg-black/5 dark:bg-white/5 text-xs font-mono">
							{license}
						</span>
					)}
				</div>
			</div>

			{/* Install */}
			<div class="flex flex-col gap-2">
				<h2 class="text-sm font-semibold uppercase tracking-wider text-black/40 dark:text-white/40">Install</h2>
				<div class="flex items-center gap-2 rounded-xl bg-black/5 dark:bg-white/5 border border-black/10 dark:border-white/10 px-4 py-3">
					<code class="text-sm font-mono flex-1">{installCmd}</code>
					<CopyButton getText={() => installCmd} />
				</div>
			</div>

			{/* Repository */}
			<div class="flex flex-col gap-2">
				<h2 class="text-sm font-semibold uppercase tracking-wider text-black/40 dark:text-white/40">Repository</h2>
				<a
					href={pkg.git}
					target="_blank"
					rel="noopener noreferrer"
					class="inline-flex items-center gap-2 text-sm text-blue-500 hover:underline"
				>
					<svg xmlns="http://www.w3.org/2000/svg" class="size-4 shrink-0" viewBox="0 0 24 24" fill="currentColor">
						<path d="M12 0C5.37 0 0 5.37 0 12c0 5.3 3.44 9.8 8.21 11.39.6.11.82-.26.82-.58v-2.03c-3.34.73-4.04-1.61-4.04-1.61-.55-1.39-1.34-1.76-1.34-1.76-1.09-.74.08-.73.08-.73 1.2.08 1.84 1.24 1.84 1.24 1.07 1.83 2.81 1.3 3.49 1 .11-.78.42-1.3.76-1.6-2.67-.3-5.47-1.33-5.47-5.93 0-1.31.47-2.38 1.24-3.22-.13-.3-.54-1.52.12-3.18 0 0 1.01-.32 3.3 1.23a11.5 11.5 0 0 1 3-.4c1.02 0 2.04.14 3 .4 2.29-1.55 3.3-1.23 3.3-1.23.66 1.66.25 2.88.12 3.18.77.84 1.24 1.91 1.24 3.22 0 4.61-2.81 5.63-5.48 5.92.43.37.81 1.1.81 2.22v3.29c0 .32.22.7.83.58C20.57 21.8 24 17.3 24 12c0-6.63-5.37-12-12-12z"/>
					</svg>
					{repoName}
				</a>
			</div>

			{/* Dependencies */}
			{deps && deps.length > 0 && (
				<div class="flex flex-col gap-2">
					<h2 class="text-sm font-semibold uppercase tracking-wider text-black/40 dark:text-white/40">Dependencies</h2>
					<div class="flex flex-wrap gap-2">
						{deps.map(([name, version]) => (
							<a
								key={name}
								href={`/registry/${name}/`}
								class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg text-xs font-mono border border-black/10 dark:border-white/10 bg-black/5 dark:bg-white/5 hover:border-blue-500/40 hover:text-blue-500 transition-colors"
							>
								{name}
								<span class="text-black/30 dark:text-white/30">{version}</span>
							</a>
						))}
					</div>
				</div>
			)}

			{/* Versions */}
			<div class="flex flex-col gap-2">
				<h2 class="text-sm font-semibold uppercase tracking-wider text-black/40 dark:text-white/40">Versions</h2>
				{versions === null ? (
					<p class="text-sm text-black/30 dark:text-white/30">Loading…</p>
				) : versions.length === 0 ? (
					<p class="text-sm text-black/30 dark:text-white/30">No versions published.</p>
				) : (
					<div class="flex flex-col divide-y divide-black/5 dark:divide-white/5 border border-black/10 dark:border-white/10 rounded-xl overflow-hidden">
						{versions.map(([version, commit]) => (
							<div key={version} class="flex items-center justify-between px-4 py-3 bg-black/[0.01] dark:bg-white/[0.01]">
								<div class="flex items-center gap-3">
									<span class="font-mono text-sm font-medium">v{version}</span>
									{version === pkg.latest && (
										<span class="text-[10px] font-medium px-1.5 py-0.5 rounded bg-green-500/10 text-green-500 border border-green-500/20 uppercase tracking-wide">
											latest
										</span>
									)}
								</div>
								<span class="font-mono text-xs text-black/30 dark:text-white/30">
									{commit.slice(0, 7)}
								</span>
							</div>
						))}
					</div>
				)}
			</div>
		</div>
	);
}
