import { useState, useEffect } from "preact/hooks";

export interface Portfile {
	name: string;
	description?: string;
	license?: string;
	authors?: string[];
	git: string;
	branch?: string;
	versions: Record<string, string>;
	dependencies?: Record<string, string>;
}

const CACHE_TTL = 5 * 60 * 1000;

function cacheKey(name: string) {
	return `lde-portfile:${name}`;
}

function loadCached(name: string): Portfile | null {
	try {
		const raw = localStorage.getItem(cacheKey(name));
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
		localStorage.setItem(
			cacheKey(name),
			JSON.stringify({ data, ts: Date.now() }),
		);
	} catch {}
}

function portfileUrl(name: string) {
	return `https://raw.githubusercontent.com/codebycruz/lpm-registry/master/packages/${name}.json`;
}

export function usePortfile(name: string) {
	const [portfile, setPortfile] = useState<Portfile | null>(() =>
		loadCached(name),
	);
	const [loading, setLoading] = useState(() => loadCached(name) === null);

	useEffect(() => {
		const cached = loadCached(name);
		if (cached) {
			setPortfile(cached);
			setLoading(false);
			return;
		}

		fetch(portfileUrl(name))
			.then((r) => (r.ok ? r.json() : null))
			.then((data: Portfile | null) => {
				if (data) {
					saveCache(name, data);
					setPortfile(data);
				}
				setLoading(false);
			})
			.catch(() => setLoading(false));
	}, [name]);

	return { portfile, loading };
}
