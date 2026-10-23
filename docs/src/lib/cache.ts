// localStorage JSON cache entries stamped with the time they were written, so
// repeat visits don't re-hit the network (or host API rate limits). A version
// can be attached to invalidate entries whose payload shape has changed.
export function readCache<T>(
	key: string,
	ttlMs: number,
	version?: number,
): T | null {
	try {
		const raw = localStorage.getItem(key);
		if (!raw) return null;
		const { data, ts, version: cachedVersion } = JSON.parse(raw);
		if (Date.now() - ts > ttlMs) return null;
		if (version !== undefined && cachedVersion !== version) return null;
		return data as T;
	} catch {
		return null;
	}
}

export function writeCache(key: string, data: unknown, version?: number) {
	try {
		localStorage.setItem(
			key,
			JSON.stringify({ data, ts: Date.now(), version }),
		);
	} catch {}
}
