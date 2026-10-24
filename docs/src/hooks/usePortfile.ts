import { useState, useEffect } from "preact/hooks";
import { readCache, writeCache } from "../lib/cache";

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

function portfileUrl(name: string) {
	return `https://raw.githubusercontent.com/lde-org/registry/master/packages/${name}.json`;
}

export function usePortfile(name: string) {
	const [portfile, setPortfile] = useState<Portfile | null>(() =>
		readCache<Portfile>(cacheKey(name), CACHE_TTL),
	);
	const [loading, setLoading] = useState(
		() => readCache<Portfile>(cacheKey(name), CACHE_TTL) === null,
	);

	useEffect(() => {
		const cached = readCache<Portfile>(cacheKey(name), CACHE_TTL);
		if (cached) {
			setPortfile(cached);
			setLoading(false);
			return;
		}

		fetch(portfileUrl(name))
			.then((r) => (r.ok ? r.json() : null))
			.then((data: Portfile | null) => {
				if (data) {
					writeCache(cacheKey(name), data);
					setPortfile(data);
				}
				setLoading(false);
			})
			.catch(() => setLoading(false));
	}, [name]);

	return { portfile, loading };
}
