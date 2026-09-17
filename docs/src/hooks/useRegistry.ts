import { useState, useEffect } from "preact/hooks";

/** One entry of the registry index (`dist/index.json`). */
export interface RegistryPackage {
	name: string;
	description: string | null;
	authors: string[];
	latest: string | null;
	git: string;
	/** When a new version was last added to this package. */
	lastUpdated: string | null;
	/** When this package was first published to the registry. */
	firstPublished: string | null;
	/**
	 * True when the dates were reconstructed from registry history rather than
	 * recorded as packages were published, so they are estimates.
	 */
	approximate?: boolean;
}

const REGISTRY_URL =
	"https://raw.githubusercontent.com/lde-org/registry/refs/heads/dist/index.json";

const CACHE_KEY = "lde-registry-index";
// Bump when the index shape changes so browsers don't serve an old payload.
const CACHE_VERSION = 2;
const CACHE_TTL = 5 * 60 * 1000;

function loadCached(): RegistryPackage[] | null {
	try {
		const raw = localStorage.getItem(CACHE_KEY);
		if (!raw) return null;
		const { data, ts, version } = JSON.parse(raw);
		if (version !== CACHE_VERSION) return null;
		if (Date.now() - ts > CACHE_TTL) return null;
		return data;
	} catch {
		return null;
	}
}

function saveCache(data: RegistryPackage[]) {
	try {
		localStorage.setItem(
			CACHE_KEY,
			JSON.stringify({ data, ts: Date.now(), version: CACHE_VERSION }),
		);
	} catch {}
}

/** Milliseconds since epoch for a date, or 0 when it is missing/unparseable. */
export function timeOf(date: string | null | undefined): number {
	if (!date) return 0;
	const time = new Date(date).getTime();
	return Number.isNaN(time) ? 0 : time;
}

function byName(a: RegistryPackage, b: RegistryPackage) {
	return a.name.localeCompare(b.name);
}

/** Newest first. Packages without a date sort last, alphabetically. */
export function sortByDate(
	packages: RegistryPackage[],
	field: "lastUpdated" | "firstPublished",
): RegistryPackage[] {
	return [...packages].sort((a, b) => {
		const ta = timeOf(a[field]);
		const tb = timeOf(b[field]);
		if (tb !== ta) return tb - ta;
		return byName(a, b);
	});
}

export function useRegistry() {
	const [packages, setPackages] = useState<RegistryPackage[]>([]);
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState<string | null>(null);

	useEffect(() => {
		const cached = loadCached();
		if (cached) {
			setPackages(cached);
			setLoading(false);
			return;
		}

		fetch(REGISTRY_URL)
			.then((r) => {
				if (!r.ok)
					throw new Error(`Failed to fetch registry (${r.status})`);
				return r.json();
			})
			.then((data: RegistryPackage[]) => {
				// The index is already sorted newest-first; this keeps the list
				// correct even if a client gets an older payload.
				const sorted = sortByDate(data, "lastUpdated");
				saveCache(sorted);
				setPackages(sorted);
				setLoading(false);
			})
			.catch((e) => {
				setError(e.message);
				setLoading(false);
			});
	}, []);

	return { packages, loading, error };
}
