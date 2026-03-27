import {
	useState,
	useEffect,
	useMemo,
	useRef,
	useCallback,
} from "preact/hooks";
import { CopyButton } from "./CopyButton";

interface Package {
	name: string;
	description: string | null;
	authors: string[];
	latest: string | null;
	git: string;
}

const REGISTRY_URL =
	"https://raw.githubusercontent.com/codebycruz/lpm-registry/refs/heads/dist/index.json";

function PackageCard({ pkg }: { pkg: Package }) {
	const installCmd = `lde add ${pkg.name}`;
	const repoName = pkg.git
		.replace(/\.git$/, "")
		.replace(/\/$/, "")
		.split("/")
		.slice(-2)
		.join("/");

	return (
		<a
			href={`/registry/${pkg.name}/`}
			class="flex flex-col gap-3 p-5 rounded-xl border border-black/10 dark:border-white/10 bg-black/[0.02] dark:bg-white/[0.02] hover:bg-black/[0.04] dark:hover:bg-white/[0.04] transition"
		>
			<div class="flex items-start justify-between gap-3">
				<div class="flex items-center gap-2 flex-wrap">
					<span class="font-semibold text-base">{pkg.name}</span>
					{pkg.latest && (
						<span class="text-xs font-mono px-1.5 py-0.5 rounded bg-blue-500/10 text-blue-500 border border-blue-500/20">
							v{pkg.latest}
						</span>
					)}
				</div>
				<a
					href={pkg.git}
					target="_blank"
					rel="noopener noreferrer"
					onClick={(e) => e.stopPropagation()}
					class="shrink-0 opacity-40 hover:opacity-100 transition-opacity mt-0.5"
					title={repoName}
				>
					<svg
						xmlns="http://www.w3.org/2000/svg"
						class="size-4"
						viewBox="0 0 24 24"
						fill="currentColor"
					>
						<path d="M12 0C5.37 0 0 5.37 0 12c0 5.3 3.44 9.8 8.21 11.39.6.11.82-.26.82-.58v-2.03c-3.34.73-4.04-1.61-4.04-1.61-.55-1.39-1.34-1.76-1.34-1.76-1.09-.74.08-.73.08-.73 1.2.08 1.84 1.24 1.84 1.24 1.07 1.83 2.81 1.3 3.49 1 .11-.78.42-1.3.76-1.6-2.67-.3-5.47-1.33-5.47-5.93 0-1.31.47-2.38 1.24-3.22-.13-.3-.54-1.52.12-3.18 0 0 1.01-.32 3.3 1.23a11.5 11.5 0 0 1 3-.4c1.02 0 2.04.14 3 .4 2.29-1.55 3.3-1.23 3.3-1.23.66 1.66.25 2.88.12 3.18.77.84 1.24 1.91 1.24 3.22 0 4.61-2.81 5.63-5.48 5.92.43.37.81 1.1.81 2.22v3.29c0 .32.22.7.83.58C20.57 21.8 24 17.3 24 12c0-6.63-5.37-12-12-12z" />
					</svg>
				</a>
			</div>

			{pkg.description && (
				<p class="text-sm text-black/60 dark:text-white/60 leading-relaxed">
					{pkg.description}
				</p>
			)}

			<div class="flex items-center gap-2 mt-1 rounded-lg bg-black/5 dark:bg-white/5 border border-black/10 dark:border-white/10 px-3 py-2">
				<code class="text-xs font-mono flex-1 text-black/70 dark:text-white/70">
					{installCmd}
				</code>
				<CopyButton getText={() => installCmd} />
			</div>
		</a>
	);
}

export default function Registry() {
	const [packages, setPackages] = useState<Package[]>([]);
	const [query, setQuery] = useState("");
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState<string | null>(null);
	const searchRef = useRef<HTMLInputElement>(null);

	const handleKeyDown = useCallback((e: KeyboardEvent) => {
		const target = e.target as HTMLElement;
		const tag = target.tagName;
		if (tag === "INPUT" || tag === "TEXTAREA" || target.isContentEditable)
			return;
		if (e.metaKey || e.ctrlKey || e.altKey) return;
		if (e.key.length === 1) {
			searchRef.current?.focus();
		}
	}, []);

	useEffect(() => {
		document.addEventListener("keydown", handleKeyDown);
		return () => document.removeEventListener("keydown", handleKeyDown);
	}, [handleKeyDown]);

	useEffect(() => {
		fetch(REGISTRY_URL)
			.then((r) => {
				if (!r.ok)
					throw new Error(`Failed to fetch registry (${r.status})`);
				return r.json();
			})
			.then((data: Package[]) => {
				setPackages(data.sort((a, b) => a.name.localeCompare(b.name)));
				setLoading(false);
			})
			.catch((e) => {
				setError(e.message);
				setLoading(false);
			});
	}, []);

	const filtered = useMemo(() => {
		const q = query.trim().toLowerCase();
		if (!q) return packages;
		return packages.filter(
			(p) =>
				p.name.toLowerCase().includes(q) ||
				(p.description ?? "").toLowerCase().includes(q),
		);
	}, [packages, query]);

	return (
		<div class="flex flex-col gap-6">
			<div class="relative">
				<svg
					xmlns="http://www.w3.org/2000/svg"
					class="absolute left-3.5 top-1/2 -translate-y-1/2 size-4 text-black/40 dark:text-white/40 pointer-events-none"
					viewBox="0 0 24 24"
					fill="none"
					stroke="currentColor"
					stroke-width="2"
					stroke-linecap="round"
					stroke-linejoin="round"
				>
					<circle cx="11" cy="11" r="8" />
					<line x1="21" y1="21" x2="16.65" y2="16.65" />
				</svg>
				<input
					ref={searchRef}
					autoFocus
					type="text"
					placeholder="Search packages..."
					value={query}
					onInput={(e) =>
						setQuery((e.target as HTMLInputElement).value)
					}
					class="w-full pl-10 pr-4 py-2.5 rounded-xl border border-black/15 dark:border-white/15 bg-black/5 dark:bg-white/5 outline-none focus:border-blue-500/50 focus:ring-2 focus:ring-blue-500/20 transition text-sm placeholder:text-black/30 dark:placeholder:text-white/30"
				/>
			</div>

			{loading && (
				<div class="flex items-center justify-center py-20 text-sm text-black/40 dark:text-white/40">
					Loading registry…
				</div>
			)}

			{error && (
				<div class="flex items-center justify-center py-20 text-sm text-red-500">
					{error}
				</div>
			)}

			{!loading && !error && (
				<>
					<p class="text-sm text-black/40 dark:text-white/40">
						{filtered.length}{" "}
						{filtered.length === 1 ? "package" : "packages"}
						{query && ` matching "${query}"`}
					</p>

					{filtered.length === 0 ? (
						<div class="flex items-center justify-center py-20 text-sm text-black/40 dark:text-white/40">
							No packages found for "{query}"
						</div>
					) : (
						<div class="grid grid-cols-1 md:grid-cols-2 gap-4">
							{filtered.map((pkg) => (
								<PackageCard key={pkg.name} pkg={pkg} />
							))}
						</div>
					)}
				</>
			)}
		</div>
	);
}
