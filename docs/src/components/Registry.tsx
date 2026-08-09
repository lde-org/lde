import {
	useState,
	useEffect,
	useMemo,
	useRef,
	useCallback,
} from "preact/hooks";

interface Package {
	name: string;
	description: string | null;
	authors: string[];
	latest: string | null;
	git: string;
	lastUpdated: string | null;
}

const REGISTRY_URL =
	"https://raw.githubusercontent.com/lde-org/registry/refs/heads/dist/index.json";

// Curated order for the "Featured" column. Packages not listed here follow alphabetically.
const FEATURED = ["hood", "cowsay", "dotenv"];

// Rows reserved per column, filled with skeleton placeholders when empty.
const COLUMN_SLOTS = 10;

function byName(a: Package, b: Package) {
	return a.name.localeCompare(b.name);
}

function byLastUpdated(a: Package, b: Package) {
	const ta = a.lastUpdated ? new Date(a.lastUpdated).getTime() : 0;
	const tb = b.lastUpdated ? new Date(b.lastUpdated).getTime() : 0;
	if (tb !== ta) return tb - ta;
	return byName(a, b);
}

function CompactCard({ pkg }: { pkg: Package }) {
	return (
		<a
			href={`/registry/${pkg.name}/`}
			class="group flex items-center justify-between gap-3 px-4 py-3 bg-black/[0.02] dark:bg-white/[0.02] hover:bg-black/[0.04] dark:hover:bg-white/[0.04] transition"
		>
			<div class="min-w-0">
				<span class="block font-semibold text-sm truncate">{pkg.name}</span>
				{pkg.description && (
					<span class="block text-xs text-black/50 dark:text-white/50 truncate mt-0.5">
						{pkg.description}
					</span>
				)}
			</div>
			<div class="flex items-center gap-2 shrink-0">
				{pkg.latest && (
					<span class="text-xs font-mono text-blue-500 dark:text-blue-400">
						v{pkg.latest}
					</span>
				)}
				<svg
					xmlns="http://www.w3.org/2000/svg"
					class="size-4 text-black/25 dark:text-white/25 group-hover:text-blue-500 dark:group-hover:text-blue-400 transition"
					viewBox="0 0 24 24"
					fill="none"
					stroke="currentColor"
					stroke-width="2"
					stroke-linecap="round"
					stroke-linejoin="round"
				>
					<path d="m9 18 6-6-6-6" />
				</svg>
			</div>
		</a>
	);
}

function Column({
	title,
	packages,
}: {
	title: string;
	packages: Package[];
}) {
	// Always reserve COLUMN_SLOTS rows so columns stay balanced even when a
	// section has fewer packages (or none at all) yet.
	const rows: (Package | null)[] = [
		...packages,
		...Array.from(
			{ length: Math.max(0, COLUMN_SLOTS - packages.length) },
			() => null,
		),
	];
	return (
		<div class="flex flex-col min-w-0">
			<h2 class="text-sm font-semibold mb-2">{title}</h2>
			<div class="flex flex-col divide-y divide-black/8 dark:divide-white/8 border border-black/10 dark:border-white/10">
				{rows.map((pkg, i) =>
					pkg ? (
						<CompactCard key={pkg.name} pkg={pkg} />
					) : (
						<div
							key={`empty-${i}`}
							class="flex items-center justify-center h-16 bg-black/[0.02] dark:bg-white/[0.02] text-black/30 dark:text-white/30 select-none"
						>
							—
						</div>
					),
				)}
			</div>
		</div>
	);
}

export default function Registry() {
	const [packages, setPackages] = useState<Package[]>([]);
	const [query, setQuery] = useState("");
	const [activeIdx, setActiveIdx] = useState(0);
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState<string | null>(null);
	const searchRef = useRef<HTMLInputElement>(null);
	const searchWrapRef = useRef<HTMLDivElement>(null);
	const listRef = useRef<HTMLUListElement>(null);

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

	// Close the dropdown when clicking anywhere outside the search box.
	useEffect(() => {
		const handler = (e: MouseEvent) => {
			if (!searchWrapRef.current?.contains(e.target as Node)) {
				setQuery("");
			}
		};
		document.addEventListener("mousedown", handler);
		return () => document.removeEventListener("mousedown", handler);
	}, []);

	useEffect(() => {
		fetch(REGISTRY_URL)
			.then((r) => {
				if (!r.ok) throw new Error(`Failed to fetch registry (${r.status})`);
				return r.json();
			})
			.then((data: Package[]) => {
				setPackages(data.sort(byName));
				setLoading(false);
			})
			.catch((e) => {
				setError(e.message);
				setLoading(false);
			});
	}, []);

	const searching = query.trim() !== "";

	const filtered = useMemo(() => {
		const q = query.trim().toLowerCase();
		if (!q) return [];
		return packages.filter(
			(p) =>
				p.name.toLowerCase().includes(q) ||
				(p.description ?? "").toLowerCase().includes(q),
		);
	}, [packages, query]);

	const featured = useMemo(() => {
		const byNameMap = new Map(packages.map((p) => [p.name, p]));
		const ordered = FEATURED.map((n) => byNameMap.get(n)).filter(
			Boolean,
		) as Package[];
		const rest = packages
			.filter((p) => !FEATURED.includes(p.name))
			.sort(byName);
		return [...ordered, ...rest];
	}, [packages]);

	const latestUpdated = useMemo(
		() => [...packages].sort(byLastUpdated),
		[packages],
	);

	// The registry index doesn't expose an "added" date yet, so "New" falls
	// back to most recently updated as the closest signal available.
	const newest = latestUpdated;

	// Reset the highlighted result when the query changes.
	useEffect(() => setActiveIdx(0), [query]);

	// Keep the highlighted result in view while navigating with the keyboard.
	useEffect(() => {
		const el = listRef.current?.children[activeIdx] as HTMLElement | undefined;
		el?.scrollIntoView({ block: "nearest" });
	}, [activeIdx]);

	const handleInputKeyDown = (e: KeyboardEvent) => {
		if (e.key === "ArrowDown" && filtered.length > 0) {
			e.preventDefault();
			setActiveIdx((i) => Math.min(i + 1, filtered.length - 1));
		} else if (e.key === "ArrowUp" && filtered.length > 0) {
			e.preventDefault();
			setActiveIdx((i) => Math.max(i - 1, 0));
		} else if (e.key === "Enter" && filtered[activeIdx]) {
			window.location.href = `/registry/${filtered[activeIdx].name}/`;
		} else if (e.key === "Escape") {
			setQuery("");
		}
	};

	return (
		<div class="flex flex-col gap-6">
			{/* Search + dropdown */}
			<div ref={searchWrapRef} class="relative">
				<svg
					xmlns="http://www.w3.org/2000/svg"
					class="absolute left-4 top-1/2 -translate-y-1/2 size-5 text-black/40 dark:text-white/40 pointer-events-none"
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
					type="text"
					placeholder="Search packages..."
					value={query}
					onInput={(e) => setQuery((e.target as HTMLInputElement).value)}
					onKeyDown={handleInputKeyDown}
					class="w-full pl-12 pr-4 py-4 text-base border border-black/15 dark:border-white/15 bg-black/5 dark:bg-white/5 outline-none focus:border-blue-600/60 focus:ring-2 focus:ring-blue-600/20 transition placeholder:text-black/30 dark:placeholder:text-white/30"
				/>
				{searching && !loading && !error && (
					<div class="absolute left-0 right-0 top-full z-20 bg-white dark:bg-gray-950 border border-black/15 dark:border-white/15 shadow-xl shadow-black/10 dark:shadow-black/40">
						{filtered.length === 0 ? (
							<div class="px-4 py-8 text-center text-sm text-black/40 dark:text-white/40">
								No packages found for "{query.trim()}"
							</div>
						) : (
							<ul ref={listRef} class="max-h-80 overflow-y-auto py-1">
								{filtered.map((pkg, i) => (
									<li key={pkg.name}>
										<a
											href={`/registry/${pkg.name}/`}
											onMouseEnter={() => setActiveIdx(i)}
											class={`flex flex-col gap-0.5 px-4 py-2.5 transition ${
												i === activeIdx
													? "bg-blue-500/10"
													: "hover:bg-black/5 dark:hover:bg-white/5"
											}`}
										>
											<span class="flex items-baseline gap-2">
												<span class="text-sm font-medium truncate">
													{pkg.name}
												</span>
												{pkg.latest && (
													<span class="text-xs font-mono text-blue-500 dark:text-blue-400 shrink-0">
														v{pkg.latest}
													</span>
												)}
											</span>
											{pkg.description && (
												<span class="text-xs text-black/50 dark:text-white/50 truncate">
													{pkg.description}
												</span>
											)}
										</a>
									</li>
								))}
							</ul>
						)}
					</div>
				)}
			</div>

			{/* Publish CTA */}
			<div class="flex justify-center mb-24">
				<a
					href="/registry/publish/"
					class="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-medium bg-blue-600 text-white hover:bg-blue-500 transition"
				>
					<svg
						xmlns="http://www.w3.org/2000/svg"
						class="size-4"
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="2"
						stroke-linecap="round"
						stroke-linejoin="round"
					>
						<path d="M5 12h14" />
						<path d="M12 5v14" />
					</svg>
					Publish a package
				</a>
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
				<div class="grid grid-cols-1 md:grid-cols-3 gap-6 md:gap-8 items-start">
					<Column
						title="Featured"
						packages={featured.slice(0, COLUMN_SLOTS)}
					/>
					<Column
						title="Latest Updated"
						packages={latestUpdated.slice(0, COLUMN_SLOTS)}
					/>
					<Column title="New" packages={newest.slice(0, COLUMN_SLOTS)} />
				</div>
			)}
		</div>
	);
}
