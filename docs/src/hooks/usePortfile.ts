import { useState, useEffect } from "preact/hooks";
import { readCache, writeCache } from "../lib/cache";

/** A version pinned to a commit, optionally overriding the portfile's source. */
export interface VersionSource {
	commit?: string;
	git?: string;
	branch?: string;
	archive?: string;
	sha256?: string;
	size?: number;
}

export type VersionEntry = string | VersionSource;

export interface Portfile {
	name: string;
	description?: string;
	license?: string;
	authors?: string[];
	tags?: string[];
	git?: string;
	branch?: string;
	versions: Record<string, VersionEntry>;
	revoked?: string[];
	dependencies?: Record<string, string>;
}

/** Commit for a version entry, regardless of whether it is a legacy string. */
export function versionCommit(entry: VersionEntry): string | undefined {
	return typeof entry === "string" ? entry : entry.commit;
}

/** Source repository for a version, falling back to the portfile default. */
export function versionGit(
	portfile: Pick<Portfile, "git">,
	entry: VersionEntry,
): string | undefined {
	return typeof entry === "string" ? portfile.git : entry.git ?? portfile.git;
}

/** Branch for a version, falling back to the portfile default. */
export function versionBranch(
	portfile: Pick<Portfile, "branch">,
	entry: VersionEntry,
): string | undefined {
	return typeof entry === "string" ? portfile.branch : entry.branch ?? portfile.branch;
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
