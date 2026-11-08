import type { APIContext } from "astro";

// Local dev has no Cloudflare runtime. The website build runs under Node, so
// fall back to process.env there without pulling in @types/node.
declare const process: { env: Record<string, string | undefined> } | undefined;

const GITHUB_API = "https://api.github.com";
const DEFAULT_GITHUB_CLIENT_ID = "Ov23li0SXnUlPdSlV5nQ";
const GITHUB_OAUTH = "https://github.com/login/oauth";
const SESSION_KEY = "github";
const STATE_KEY = "oauthState";
const TOKEN_SKEW_SECONDS = 60;

export interface GithubUser {
	login: string;
	id: number;
	avatarUrl: string | null;
}

export interface GithubSession {
	accessToken: string;
	refreshToken?: string;
	expiresAt?: number;
	refreshExpiresAt?: number;
	user: GithubUser;
}

interface GithubEnv {
	GITHUB_CLIENT_ID?: string;
	GITHUB_CLIENT_SECRET?: string;
	REGISTRY_REPO?: string;
	REGISTRY_BRANCH?: string;
	SITE_URL?: string;
}

/** The subset shared by APIContext and Astro's page global. */
export interface SessionContext {
	session?: APIContext["session"];
	url: URL;
	locals: App.Locals;
}

interface TokenResponse {
	access_token?: string;
	refresh_token?: string;
	expires_in?: number;
	refresh_token_expires_in?: number;
	error?: string;
	error_description?: string;
}

export function getEnv(context: SessionContext): GithubEnv {
	return (
		context.locals.runtime?.env ??
		(typeof process === "undefined" ? {} : process.env)
	);
}

export function getOrigin(context: SessionContext): string {
	const configured = getEnv(context).SITE_URL;
	if (configured) return configured.replace(/\/+$/, "");
	return context.url.origin;
}

export function getRegistryRepo(context: SessionContext): string {
	const configured = getEnv(context).REGISTRY_REPO ?? "lde-org/registry";
	if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(configured)) {
		throw new Error("REGISTRY_REPO must be owner/repo");
	}
	return configured;
}

export function getRegistryBranch(context: SessionContext): string {
	return getEnv(context).REGISTRY_BRANCH ?? "master";
}

function requireGithubConfig(context: SessionContext) {
	const env = getEnv(context);
	const clientId = env.GITHUB_CLIENT_ID ?? DEFAULT_GITHUB_CLIENT_ID;
	if (!env.GITHUB_CLIENT_SECRET) {
		throw new Error("GitHub login is not configured. Set GITHUB_CLIENT_SECRET.");
	}
	return { clientId, clientSecret: env.GITHUB_CLIENT_SECRET };
}

export function hasGithubConfig(context: SessionContext): boolean {
	const env = getEnv(context);
	return Boolean((env.GITHUB_CLIENT_ID ?? DEFAULT_GITHUB_CLIENT_ID) && env.GITHUB_CLIENT_SECRET);
}

export function createOAuthState(): string {
	const bytes = new Uint8Array(32);
	crypto.getRandomValues(bytes);
	return btoa(String.fromCharCode(...bytes))
		.replace(/\+/g, "-")
		.replace(/\//g, "_")
		.replace(/=+$/, "");
}

export function authorizeUrl(context: APIContext, state: string): string {
	const { clientId } = requireGithubConfig(context);
	const url = new URL("https://github.com/login/oauth/authorize");
	url.searchParams.set("client_id", clientId);
	url.searchParams.set("redirect_uri", `${getOrigin(context)}/api/auth/callback`);
	url.searchParams.set("state", state);
	url.searchParams.set("allow_signup", "false");
	// Public repositories are enough for the public registry; offline_access
	// forces an expiring token with a refresh token.
	url.searchParams.set("scope", "public_repo offline_access");
	return url.toString();
}

async function readGithubResponse(response: Response): Promise<TokenResponse> {
	const text = await response.text();
	try {
		return JSON.parse(text) as TokenResponse;
	} catch {
		const fields: Record<string, string> = {};
		for (const [key, value] of new URLSearchParams(text)) fields[key] = value;
		return fields as TokenResponse;
	}
}

function tokenError(data: TokenResponse): string {
	return (
		data.error_description ??
		data.error ??
		"GitHub did not return an access token"
	);
}

async function tokenRequest(
	context: SessionContext,
	fields: Record<string, string>,
): Promise<TokenResponse> {
	const { clientId, clientSecret } = requireGithubConfig(context);
	const body = new URLSearchParams({
		client_id: clientId,
		client_secret: clientSecret,
		...fields,
	});
	const response = await fetch(`${GITHUB_OAUTH}/access_token`, {
		method: "POST",
		headers: {
			Accept: "application/json",
			"Content-Type": "application/x-www-form-urlencoded",
			"User-Agent": "lde-website",
		},
		body,
	});
	const data = await readGithubResponse(response);
	if (data.error || !data.access_token) throw new Error(tokenError(data));
	return data;
}

export async function exchangeCode(
	context: SessionContext,
	code: string,
): Promise<GithubSession> {
	const data = await tokenRequest(context, {
		code,
		redirect_uri: `${getOrigin(context)}/api/auth/callback`,
	});
	const user = await fetchUser(data.access_token as string);
	const now = Math.floor(Date.now() / 1000);
	return {
		accessToken: data.access_token as string,
		refreshToken: data.refresh_token,
		expiresAt: data.expires_in ? now + data.expires_in : undefined,
		refreshExpiresAt: data.refresh_token_expires_in
			? now + data.refresh_token_expires_in
			: undefined,
		user,
	};
}

async function refreshSession(
	context: SessionContext,
	session: GithubSession,
): Promise<GithubSession> {
	if (!session.refreshToken) throw new Error("No refresh token is stored.");
	const now = Math.floor(Date.now() / 1000);
	if (session.refreshExpiresAt && session.refreshExpiresAt - TOKEN_SKEW_SECONDS <= now) {
		throw new Error("The GitHub session expired; sign in again.");
	}
	const data = await tokenRequest(context, {
		grant_type: "refresh_token",
		refresh_token: session.refreshToken,
	});
	const refreshedAt = Math.floor(Date.now() / 1000);
	return {
		accessToken: data.access_token as string,
		refreshToken: data.refresh_token ?? session.refreshToken,
		expiresAt: data.expires_in ? refreshedAt + data.expires_in : session.expiresAt,
		refreshExpiresAt: data.refresh_token_expires_in
			? refreshedAt + data.refresh_token_expires_in
			: session.refreshExpiresAt,
		user: session.user,
	};
}

export async function getGithubSession(
	context: SessionContext,
): Promise<GithubSession | null> {
	const stored = await context.session?.get(SESSION_KEY);
	if (!stored) return null;

	const now = Math.floor(Date.now() / 1000);
	const isExpired =
		typeof stored.expiresAt === "number" &&
		stored.expiresAt - TOKEN_SKEW_SECONDS <= now;
	if (!isExpired) return stored;

	try {
		const refreshed = await refreshSession(context, stored);
		await context.session?.set(SESSION_KEY, refreshed);
		return refreshed;
	} catch {
		await context.session?.delete(SESSION_KEY);
		return null;
	}
}

export async function setGithubSession(
	context: APIContext,
	session: GithubSession,
): Promise<void> {
	await context.session?.set(SESSION_KEY, session);
}

export async function clearGithubSession(context: APIContext): Promise<void> {
	await context.session?.destroy();
}

export async function setOAuthState(
	context: APIContext,
	state: string,
): Promise<void> {
	await context.session?.set(STATE_KEY, state);
}

export async function takeOAuthState(
	context: APIContext,
): Promise<string | undefined> {
	const state = await context.session?.get(STATE_KEY);
	await context.session?.delete(STATE_KEY);
	return state;
}

async function fetchUser(token: string): Promise<GithubUser> {
	const response = await fetch(`${GITHUB_API}/user`, {
		headers: githubHeaders(token),
	});
	if (!response.ok) {
		throw new Error(`GitHub user request failed (${response.status}).`);
	}
	const data = (await response.json()) as {
		login?: string;
		id?: number;
		avatar_url?: string | null;
	};
	if (!data.login || typeof data.id !== "number") {
		throw new Error("GitHub returned a malformed user response.");
	}
	return {
		login: data.login,
		id: data.id,
		avatarUrl: data.avatar_url ?? null,
	};
}

function githubHeaders(token: string): HeadersInit {
	return {
		Accept: "application/vnd.github+json",
		Authorization: `Bearer ${token}`,
		"User-Agent": "lde-website",
		"X-GitHub-Api-Version": "2022-11-28",
	};
}

export async function githubRequest<T>(
	token: string,
	path: string,
	init: RequestInit = {},
): Promise<T> {
	const response = await fetch(`${GITHUB_API}${path}`, {
		...init,
		headers: {
			...githubHeaders(token),
			...(init.body ? { "Content-Type": "application/json" } : {}),
			...init.headers,
		},
	});
	const text = await response.text();
	const data = text ? (JSON.parse(text) as { message?: string }) : null;
	if (!response.ok) {
		throw new Error(data?.message ?? `GitHub request failed (${response.status}).`);
	}
	return data as T;
}

export function assertSameOrigin(context: APIContext): void {
	const origin = context.request.headers.get("origin");
	if (origin && origin !== getOrigin(context)) {
		throw new Error("Cross-origin request rejected.");
	}
}

export function json(data: unknown, status = 200): Response {
	return Response.json(data, { status });
}

interface RepoInfo {
	default_branch?: string;
	permissions?: { push?: boolean; admin?: boolean };
}

interface ForkInfo {
	full_name: string;
	owner?: { login?: string };
}

interface PullRequestInfo {
	number: number;
	html_url: string;
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

async function ensureFork(
	token: string,
	repo: string,
	base: string,
): Promise<ForkInfo> {
	const fork = await githubRequest<ForkInfo>(token, `/repos/${repo}/forks`, {
		method: "POST",
		body: JSON.stringify({ default_branch_only: true }),
	});
	for (let attempt = 0; attempt < 10; attempt += 1) {
		try {
			await githubRequest(token, `/repos/${fork.full_name}/git/ref/heads/${base}`);
			return fork;
		} catch {
			await sleep(1000);
		}
	}
	throw new Error("Fork created but its base branch is not ready yet.");
}

/**
 * Create a branch + commit + pull request. Users without write access push to
 * a fork, matching how GitHub's own web editor submits changes.
 */
export async function createFilePullRequest(opts: {
	token: string;
	repo: string;
	path: string;
	content: string;
	branch: string;
	title: string;
	body: string;
}): Promise<PullRequestInfo> {
	const info = await githubRequest<RepoInfo>(opts.token, `/repos/${opts.repo}`);
	const base = info.default_branch ?? "master";
	const canPush = info.permissions?.push === true;

	let headRepo = opts.repo;
	let headOwner = opts.repo.split("/")[0];
	if (!canPush) {
		const fork = await ensureFork(opts.token, opts.repo, base);
		headRepo = fork.full_name;
		headOwner = fork.owner?.login ?? fork.full_name.split("/")[0];
		try {
			await githubRequest(opts.token, `/repos/${headRepo}/merge-upstream`, {
				method: "POST",
				body: JSON.stringify({ branch: base }),
			});
		} catch {
			// A fork that is already current returns 409.
		}
	}

	const ref = await githubRequest<{ object: { sha: string } }>(
		opts.token,
		`/repos/${headRepo}/git/ref/heads/${base}`,
	);
	const blob = await githubRequest<{ sha: string }>(
		opts.token,
		`/repos/${headRepo}/git/blobs`,
		{
			method: "POST",
			body: JSON.stringify({ content: opts.content, encoding: "utf-8" }),
		},
	);
	const baseCommit = await githubRequest<{ tree: { sha: string } }>(
		opts.token,
		`/repos/${headRepo}/git/commits/${ref.object.sha}`,
	);
	const tree = await githubRequest<{ sha: string }>(
		opts.token,
		`/repos/${headRepo}/git/trees`,
		{
			method: "POST",
			body: JSON.stringify({
				base_tree: baseCommit.tree.sha,
				tree: [
					{
						path: opts.path,
						mode: "100644",
						type: "blob",
						sha: blob.sha,
					},
				],
			}),
		},
	);
	const commit = await githubRequest<{ sha: string }>(
		opts.token,
		`/repos/${headRepo}/git/commits`,
		{
			method: "POST",
			body: JSON.stringify({
				message: opts.title,
				tree: tree.sha,
				parents: [ref.object.sha],
			}),
		},
	);

	let branch = opts.branch;
	try {
		await githubRequest(opts.token, `/repos/${headRepo}/git/refs`, {
			method: "POST",
			body: JSON.stringify({ ref: `refs/heads/${branch}`, sha: commit.sha }),
		});
	} catch (error) {
		if (!(error instanceof Error) || !error.message.includes("already exists")) {
			throw error;
		}
		branch = `${branch}-${Date.now()}`;
		await githubRequest(opts.token, `/repos/${headRepo}/git/refs`, {
			method: "POST",
			body: JSON.stringify({ ref: `refs/heads/${branch}`, sha: commit.sha }),
		});
	}

	return githubRequest<PullRequestInfo>(opts.token, `/repos/${opts.repo}/pulls`, {
		method: "POST",
		body: JSON.stringify({
			title: opts.title,
			head: headOwner === opts.repo.split("/")[0] ? branch : `${headOwner}:${branch}`,
			base,
			body: opts.body,
		}),
	});
}
