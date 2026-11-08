import type { APIContext } from "astro";
import {
	getRegistryBranch,
	getRegistryRepo,
	githubRequest,
} from "./github";

export const PACKAGE_RE = /^(?:[a-z][a-z0-9_-]{1,}[a-z0-9]\/)?[a-z](?:[a-z0-9_-]*[a-z0-9])?$/;
export const NAMESPACE_RE = /^[a-z][a-z0-9_-]{1,}[a-z0-9]$/;

export interface Authority {
	namespaces: Record<string, number[]>;
	top: Record<string, number[]>;
}

export interface OwnerInfo {
	id: number;
	login: string | null;
}

export interface Portfile {
	name: string;
	git?: string;
	branch?: string;
	versions?: Record<string, unknown>;
	revoked?: string[];
	[key: string]: unknown;
}

export interface IndexEntry {
	name: string;
	latest: string | null;
	git: string | null;
	description?: string | null;
}

export function validatePackage(name: unknown): string {
	if (typeof name !== "string" || name.length > 128 || !PACKAGE_RE.test(name)) {
		throw new Error("Invalid package name.");
	}
	return name;
}

export function validateNamespace(name: unknown): string {
	if (
		typeof name !== "string" ||
		name.length < 3 ||
		name.length > 128 ||
		!NAMESPACE_RE.test(name)
	) {
		throw new Error("Invalid namespace name.");
	}
	return name;
}

export function sortedObject<T>(value: Record<string, T>): Record<string, T> {
	const result: Record<string, T> = {};
	for (const key of Object.keys(value).sort()) result[key] = value[key];
	return result;
}

export function normalizeAuthority(value: unknown): Authority {
	const source = value && typeof value === "object" ? value : {};
	const namespaces = "namespaces" in source ? source.namespaces : {};
	const top = "top" in source ? source.top : {};
	const normalizeMap = (map: unknown): Record<string, number[]> => {
		const result: Record<string, number[]> = {};
		if (!map || typeof map !== "object") return result;
		for (const [key, owners] of Object.entries(map)) {
			if (!Array.isArray(owners)) continue;
			result[key] = owners.filter(
				(owner): owner is number => typeof owner === "number",
			);
		}
		return result;
	};
	return { namespaces: normalizeMap(namespaces), top: normalizeMap(top) };
}

export async function readRegistryJson<T>(
	repo: string,
	branch: string,
	path: string,
): Promise<T | null> {
	const response = await fetch(
		`https://raw.githubusercontent.com/${repo}/${branch}/${path}`,
		{ headers: { Accept: "application/json", "User-Agent": "lde-website" } },
	);
	if (response.status === 404) return null;
	if (!response.ok) throw new Error(`Could not read ${path} (${response.status}).`);
	return (await response.json()) as T;
}

export async function readAuthority(
	repo: string,
	branch: string,
): Promise<Authority> {
	return normalizeAuthority(await readRegistryJson(repo, branch, "authority.json"));
}

export async function readPortfile(
	repo: string,
	branch: string,
	name: string,
): Promise<Portfile | null> {
	return readRegistryJson<Portfile>(repo, branch, `packages/${name}.json`);
}

export async function readIndex(repo: string): Promise<IndexEntry[]> {
	return (await readRegistryJson<IndexEntry[]>(repo, "dist", "index.json")) ?? [];
}

export function ownersFor(authority: Authority, name: string): number[] {
	const namespace = name.split("/")[0] ?? "";
	return name.includes("/")
		? authority.namespaces[namespace] ?? []
		: authority.top[name] ?? [];
}

export function parseGitHubRepo(git: string | undefined): { owner: string; repo: string } | null {
	if (!git) return null;
	const cleaned = git.replace(/\.git$/, "").replace(/\/+$/, "");
	const https = cleaned.match(/^https?:\/\/github\.com\/([^/]+)\/([^/]+)$/);
	if (https) return { owner: https[1], repo: https[2] };
	const ssh = cleaned.match(/^git@github\.com:([^/]+)\/([^/]+)$/);
	if (ssh) return { owner: ssh[1], repo: ssh[2] };
	const proto = cleaned.match(/^ssh:\/\/git@github\.com\/([^/]+)\/([^/]+)$/);
	if (proto) return { owner: proto[1], repo: proto[2] };
	return null;
}

export function ownerKey(name: string): { map: "namespaces" | "top"; key: string } {
	if (name.includes("/")) {
		return { map: "namespaces", key: name.split("/")[0] ?? "" };
	}
	return { map: "top", key: name };
}

export async function isAdmin(
	context: APIContext,
	token: string,
	login: string,
): Promise<boolean> {
	try {
		const repo = getRegistryRepo(context);
		const permission = await githubRequest<{ permission?: string }>(
			token,
			`/repos/${repo}/collaborators/${login}/permission`,
		);
		return permission.permission === "admin" || permission.permission === "write";
	} catch {
		return false;
	}
}

export async function loginFor(id: number, token?: string): Promise<string | null> {
	try {
		const headers: HeadersInit = {
			Accept: "application/vnd.github+json",
			"User-Agent": "lde-website",
		};
		if (token) headers.Authorization = `Bearer ${token}`;
		const response = await fetch(`https://api.github.com/user/${id}`, { headers });
		if (!response.ok) return null;
		const user = (await response.json()) as { login?: string };
		return user.login ?? null;
	} catch {
		return null;
	}
}

export async function ownerInfos(
	ids: number[],
	token: string | undefined,
	cache: Map<number, Promise<string | null>>,
): Promise<OwnerInfo[]> {
	return Promise.all(
		ids.map(async (id) => {
			let login = cache.get(id);
			if (!login) {
				login = loginFor(id, token);
				cache.set(id, login);
			}
			return { id, login: await login };
		}),
	);
}

export function isOwner(authority: Authority, name: string, userId: number): boolean {
	return ownersFor(authority, name).includes(userId);
}
