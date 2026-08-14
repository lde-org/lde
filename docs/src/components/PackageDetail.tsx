import { useState, useEffect, useMemo } from "preact/hooks";
import { Marked } from "marked";
import DOMPurify from "dompurify";
import { CopyButton } from "./CopyButton";
import { usePortfile } from "../hooks/usePortfile";
import { useRegistry } from "../hooks/useRegistry";

// Fetch with a localStorage cache: returns cached data when fresh, otherwise
// fetches and stores the result. Used for the README and repo tree fetches so
// repeat visits don't re-hit the network (or host API rate limits).
function cachedFetch<T>(
	key: string,
	url: string,
	ttlMs: number,
	parse: (r: Response) => Promise<T | null>,
): Promise<T | null> {
	try {
		const raw = localStorage.getItem(key);
		if (raw) {
			const { data, ts } = JSON.parse(raw);
			if (Date.now() - ts <= ttlMs) return Promise.resolve(data as T);
		}
	} catch {}
	return fetch(url)
		.then((r) => (r.ok ? parse(r) : Promise.resolve(null)))
		.then((data) => {
			if (data != null) {
				try {
					localStorage.setItem(
						key,
						JSON.stringify({ data, ts: Date.now() }),
					);
				} catch {}
			}
			return data;
		});
}

function getNameFromUrl(): string | null {
	const match = window.location.pathname.match(/^\/registry\/([^/]+)\/?$/);
	return match ? match[1] : null;
}

function parseAuthor(author: string) {
	const match = author.match(/^(.*?)\s*<([^>]+)>\s*$/);
	if (match) return { name: match[1].trim(), email: match[2] };
	return { name: author, email: null };
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

function computeLatest(versions: Record<string, string>): string | null {
	const sorted = sortedVersions(versions);
	return sorted.length > 0 ? sorted[0][0] : null;
}

function formatDate(iso: string) {
	return new Date(iso).toLocaleDateString("en-US", {
		year: "numeric",
		month: "short",
		day: "numeric",
	});
}

function formatSize(bytes: number): string {
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} kB`;
	return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

type Host = "github" | "gitlab" | "codeberg" | "bitbucket";

interface Repo {
	host: Host;
	owner: string;
	repo: string;
}

// Parse a package git URL into host + owner + repo. Only hosts with public
// raw-file endpoints and tree APIs are supported: GitHub, GitLab, Codeberg
// (Forgejo/Gitea), and Bitbucket.
const HOSTS: Record<string, Host> = {
	"github.com": "github",
	"gitlab.com": "gitlab",
	"codeberg.org": "codeberg",
	"bitbucket.org": "bitbucket",
};
function parseGitUrl(git: string): Repo | null {
	const m = git.replace(/\.git$/, "").match(
		/^https?:\/\/(github\.com|gitlab\.com|codeberg\.org|bitbucket\.org)\/([^/]+)\/([^/]+)/,
	);
	if (!m) return null;
	return { host: HOSTS[m[1]], owner: m[2], repo: m[3] };
}

// Codeberg's URLs scope the ref as either a branch or a commit — a 40-char
// hex string is a commit SHA, anything else (branch, tag, HEAD) is a branch.
const SHA_RE = /^[0-9a-f]{40}$/;
function refScope(ref: string): "branch" | "commit" {
	return SHA_RE.test(ref) ? "commit" : "branch";
}

// Raw file URL at a pinned ref (branch, tag, commit SHA, or HEAD).
function repoRawUrl(repo: Repo, ref: string, path: string): string {
	switch (repo.host) {
		case "github":
			return `https://raw.githubusercontent.com/${repo.owner}/${repo.repo}/${ref}/${path}`;
		case "gitlab":
			return `https://gitlab.com/${repo.owner}/${repo.repo}/-/raw/${ref}/${path}`;
		case "codeberg":
			return `https://codeberg.org/${repo.owner}/${repo.repo}/raw/${refScope(ref)}/${ref}/${path}`;
		case "bitbucket":
			return `https://bitbucket.org/${repo.owner}/${repo.repo}/raw/${ref}/${path}`;
	}
}

// Web URL for browsing a file (blob) or directory (tree) at a pinned ref.
function repoWebUrl(
	repo: Repo,
	ref: string,
	path: string,
	kind: "blob" | "tree",
): string {
	switch (repo.host) {
		case "github":
			return `https://github.com/${repo.owner}/${repo.repo}/${kind}/${ref}/${path}`;
		case "gitlab":
			return `https://gitlab.com/${repo.owner}/${repo.repo}/-/${kind}/${ref}/${path}`;
		case "codeberg":
			return `https://codeberg.org/${repo.owner}/${repo.repo}/src/${refScope(ref)}/${ref}/${path}`;
		case "bitbucket":
			return `https://bitbucket.org/${repo.owner}/${repo.repo}/src/${ref}/${path}`;
	}
}

// Resolve a README.md URL for a supported host, pinned to the given ref
// (commit SHA, branch, or HEAD). Codeberg's raw and GitLab's -/raw endpoints
// send no CORS headers, so those hosts fetch through their CORS-enabled APIs;
// GitHub's and Bitbucket's raw endpoints allow cross-origin reads directly.
function repoReadmeUrl(repo: Repo, ref: string): string {
	switch (repo.host) {
		case "github":
			return `https://raw.githubusercontent.com/${repo.owner}/${repo.repo}/${ref}/README.md`;
		case "gitlab": {
			const project = encodeURIComponent(`${repo.owner}/${repo.repo}`);
			return `https://gitlab.com/api/v4/projects/${project}/repository/files/README.md/raw?ref=${encodeURIComponent(ref)}`;
		}
		case "codeberg":
			return `https://codeberg.org/api/v1/repos/${repo.owner}/${repo.repo}/raw/README.md?ref=${encodeURIComponent(ref)}`;
		case "bitbucket":
			return `https://bitbucket.org/${repo.owner}/${repo.repo}/raw/${ref}/README.md`;
	}
}

// Rewrite a relative README image path to its raw host URL at the pinned
// ref. Absolute URLs, anchors, and data: URIs are left untouched.
function resolveAssetUrl(
	href: string,
	repo: Repo | null,
	ref: string,
): string {
	if (
		!repo ||
		/^(https?:)?\/\//.test(href) ||
		href.startsWith("data:") ||
		href.startsWith("#")
	)
		return href;
	const clean = href.replace(/^\.\//, "").replace(/^\/+/, "");
	return repoRawUrl(repo, ref, clean);
}

// Rewrite a relative README link to its host blob URL at the pinned ref.
function resolveLinkUrl(
	href: string,
	repo: Repo | null,
	ref: string,
): string {
	if (
		!repo ||
		/^(https?:)?\/\//.test(href) ||
		href.startsWith("mailto:") ||
		href.startsWith("tel:") ||
		href.startsWith("data:") ||
		href.startsWith("#")
	)
		return href;
	const clean = href.replace(/^\.\//, "").replace(/^\/+/, "");
	return repoWebUrl(repo, ref, clean, "blob");
}

// Render a README with marked (GFM) and sanitize the result, then resolve
// relative image and link URLs against the package's host URLs at the pinned
// ref so they work outside the repo page.
function renderReadme(
	src: string,
	repo: Repo | null,
	ref: string,
): string {
	const html = DOMPurify.sanitize(
		new Marked({ gfm: true }).parse(src) as string,
	);
	if (!repo) return html;
	// This runs after sanitizing, so only safe URLs remain; rewriting a
	// relative URL into an absolute one cannot reintroduce anything.
	return html
		.replace(
			/(<img\b[^>]*\bsrc=["'])([^"']+)(["'])/g,
			(_m, pre, val, post) =>
				pre + resolveAssetUrl(val, repo, ref) + post,
		)
		.replace(
			/(<a\b[^>]*\bhref=["'])([^"']+)(["'])/g,
			(_m, pre, val, post) =>
				pre + resolveLinkUrl(val, repo, ref) + post,
		);
}


type Tab = "overview" | "versions" | "files";

const TABS: { id: Tab; label: string }[] = [
	{ id: "overview", label: "Overview" },
	{ id: "versions", label: "Versions" },
	{ id: "files", label: "Files" },
];

interface GitTreeNode {
	path: string;
	type: "blob" | "tree";
	size?: number;
}

const TREE_TTL = 15 * 60 * 1000;
const PER_PAGE = 100;
const MAX_PAGES = 25;

// Fetch the flattened file tree of a repo at a pinned ref from the host's
// tree API:
//  - GitHub truncates huge trees; keep the top two levels in that case.
//  - GitLab and Codeberg paginate; fetch until a short (or empty) page.
//  - Bitbucket flattens with max_depth=0 and paginates with an opaque cursor.
async function fetchFileTree(repo: Repo, ref: string): Promise<GitTreeNode[]> {
	switch (repo.host) {
		case "github": {
			const url = `https://api.github.com/repos/${repo.owner}/${repo.repo}/git/trees/${ref}?recursive=1`;
			const data = await cachedFetch<{
				tree?: GitTreeNode[];
				truncated?: boolean;
			}>(
				`lde-tree:${repo.owner}/${repo.repo}/${ref}`,
				url,
				TREE_TTL,
				(r) => r.json(),
			);
			if (!data) throw new Error("GitHub API request failed");
			const nodes = data.tree ?? [];
			// Huge repos get truncated — keep only the top two levels so the
			// listing stays usable.
			return data.truncated
				? nodes.filter((n) => n.path.split("/").length <= 2)
				: nodes;
		}
		case "gitlab": {
			const project = encodeURIComponent(`${repo.owner}/${repo.repo}`);
			const all: GitTreeNode[] = [];
			for (let page = 1; page <= MAX_PAGES; page++) {
				const url = `https://gitlab.com/api/v4/projects/${project}/repository/tree?ref=${encodeURIComponent(ref)}&recursive=true&per_page=${PER_PAGE}&page=${page}`;
				const entries = await cachedFetch<
					{ path: string; type: "blob" | "tree"; size?: number }[]
				>(`lde-tree:${url}`, url, TREE_TTL, (r) => r.json());
				if (!entries) throw new Error("GitLab API request failed");
				if (entries.length === 0) break;
				for (const e of entries)
					all.push({
						path: e.path,
						type: e.type === "tree" ? "tree" : "blob",
						size: e.size,
					});
				if (entries.length < PER_PAGE) break;
			}
			return all;
		}
		case "codeberg": {
			const all: GitTreeNode[] = [];
			for (let page = 1; page <= MAX_PAGES; page++) {
				const url = `https://codeberg.org/api/v1/repos/${repo.owner}/${repo.repo}/git/trees/${ref}?recursive=true&per_page=${PER_PAGE}&page=${page}`;
				const data = await cachedFetch<{
					tree?: { path: string; type: string; size?: number }[];
				}>(`lde-tree:${url}`, url, TREE_TTL, (r) => r.json());
				if (!data) throw new Error("Codeberg API request failed");
				const entries = data.tree ?? [];
				if (entries.length === 0) break;
				for (const e of entries)
					all.push({
						path: e.path,
						type: e.type === "tree" ? "tree" : "blob",
						size: e.size,
					});
				if (entries.length < PER_PAGE) break;
			}
			return all;
		}
		case "bitbucket": {
			const all: GitTreeNode[] = [];
			const base = `https://api.bitbucket.org/2.0/repositories/${repo.owner}/${repo.repo}/src/${ref}/?format=json&max_depth=0&pagelen=${PER_PAGE}`;
			let cursor: string | null = base;
			for (let pages = 0; pages < MAX_PAGES && cursor; pages++) {
				const pageUrl: string = cursor;
				const data: {
					values?: { path: string; type: string; size?: number }[];
					next?: string | null;
				} | null = await cachedFetch<{
					values?: { path: string; type: string; size?: number }[];
					next?: string | null;
				}>(`lde-tree:${pageUrl}`, pageUrl, TREE_TTL, (r) => r.json());
				if (!data) throw new Error("Bitbucket API request failed");
				for (const v of data.values ?? []) {
					if (v.type === "commit_file")
						all.push({ path: v.path, type: "blob", size: v.size });
					else if (v.type === "commit_directory")
						all.push({ path: v.path, type: "tree" });
				}
				cursor = data.next ?? null;
			}
			return all;
		}
	}
}

// A nested node in the file tree — children are the entries directly inside
// a directory.
interface TreeNode extends GitTreeNode {
	children: TreeNode[];
}

// Build a nested tree from the flat GitHub trees API response. Entries come
// back with full paths ("src/init.lua"); parent directories the API didn't
// include explicitly are synthesized so every file still nests under its
// folders.
function buildTree(entries: GitTreeNode[]): TreeNode[] {
	const nodes = new Map<string, TreeNode>();
	const ensure = (path: string): TreeNode => {
		let node = nodes.get(path);
		if (!node) {
			node = { path, type: "tree", children: [] };
			nodes.set(path, node);
		}
		return node;
	};

	// Create a node for every entry, normalizing trailing slashes.
	for (const entry of entries) {
		const path = entry.path.replace(/\/+$/, "");
		const node = ensure(path);
		node.type = entry.type;
		if (entry.type === "blob") node.size = entry.size;
	}

	// Link each node under its parent directory.
	const root: TreeNode[] = [];
	for (const [path, node] of nodes) {
		const slash = path.lastIndexOf("/");
		if (slash === -1) root.push(node);
		else ensure(path.slice(0, slash)).children.push(node);
	}

	// Directories first, then files — both alphabetical, per level.
	const sortLevel = (level: TreeNode[]) => {
		level.sort((a, b) => {
			if (a.type !== b.type) return a.type === "tree" ? -1 : 1;
			return a.path.localeCompare(b.path);
		});
		for (const node of level)
			if (node.type === "tree") sortLevel(node.children);
	};
	sortLevel(root);
	return root;
}

export default function PackageDetail({ name: nameProp }: { name: string }) {
	const [name, setName] = useState(nameProp);

	useEffect(() => {
		if (nameProp === "_fallback") {
			const urlName = getNameFromUrl();
			if (urlName) setName(urlName);
		}
	}, [nameProp]);

	const { portfile, loading: portfileLoading } = usePortfile(
		name !== "_fallback" ? name : "",
	);
	const { packages, loading: registryLoading } = useRegistry();

	const pkg = packages.find((p) => p.name === name) ?? null;

	const loading =
		name === "_fallback" || portfileLoading || (registryLoading && !pkg);

	const [readme, setReadme] = useState<string | null>(null);
	const [readmeLoading, setReadmeLoading] = useState(false);
	const [tab, setTab] = useState<Tab>("overview");

	const [tree, setTree] = useState<GitTreeNode[] | null>(null);
	const [treeLoading, setTreeLoading] = useState(false);
	const [treeError, setTreeError] = useState<string | null>(null);

	const description = portfile?.description ?? pkg?.description ?? null;
	const authors = portfile?.authors ?? pkg?.authors ?? [];
	const git = portfile?.git ?? pkg?.git ?? "";
	const latest =
		pkg?.latest ?? (portfile ? computeLatest(portfile.versions) : null);
	const lastUpdated = pkg?.lastUpdated ?? null;
	const license = portfile?.license ?? null;
	const deps = portfile?.dependencies
		? Object.entries(portfile.dependencies)
		: null;
	const versions = portfile ? sortedVersions(portfile.versions) : null;

	const latestCommit = portfile?.versions?.[latest ?? ""] ?? null;
	const repo = parseGitUrl(git);
	const treeRef = latestCommit ?? portfile?.branch ?? "HEAD";
	const readmeUrl = repo ? repoReadmeUrl(repo, latestCommit ?? "HEAD") : null;

	// Try to resolve a README.md from the package's repo at the pinned commit
	// of the latest version (falling back to the default branch). Cached
	// locally — the content is immutable per commit, so it's held for a day.
	useEffect(() => {
		setReadme(null);
		setReadmeLoading(false);
		if (!readmeUrl) return;
		setReadmeLoading(true);
		cachedFetch<string | null>(
			`lde-readme:${readmeUrl}`,
			readmeUrl,
			24 * 60 * 60 * 1000,
			(r) => r.text(),
		)
			.then((text) => {
				setReadme(text);
				setReadmeLoading(false);
			})
			.catch(() => setReadmeLoading(false));
	}, [readmeUrl]);

	// Fetch the full file tree of the latest commit from the host's tree API.
	// Only fetched once the Files tab is opened, and cached locally for 15
	// minutes to stay well under unauthenticated rate limits.
	useEffect(() => {
		setTree(null);
		setTreeLoading(false);
		setTreeError(null);
		if (tab !== "files" || !repo) return;
		setTreeLoading(true);
		fetchFileTree(repo, treeRef)
			.then((nodes) => {
				setTree(nodes);
				setTreeLoading(false);
			})
			.catch((e: Error) => {
				setTreeError(e.message);
				setTreeLoading(false);
			});
	}, [tab, repo?.host, repo?.owner, repo?.repo, treeRef]);

	// Rendered README HTML — memoized so marked only re-parses when the
	// source or the pinned ref changes.
	const readmeHtml = useMemo(
		() => (readme ? renderReadme(readme, repo, treeRef) : null),
		[readme, repo?.host, repo?.owner, repo?.repo, treeRef],
	);

	if (loading) {
		return (
			<div class="flex flex-col gap-8 animate-pulse">
				<div class="flex flex-col gap-3">
					<div class="h-9 w-48 bg-black/10 dark:bg-white/10" />
					<div class="h-4 w-96 max-w-full bg-black/5 dark:bg-white/5" />
				</div>
				<div class="h-12 bg-black/5 dark:bg-white/5" />
				<div class="h-6 w-32 bg-black/5 dark:bg-white/5" />
			</div>
		);
	}

	if (!portfile && !pkg) {
		return (
			<div class="flex flex-col gap-4 py-12 text-center">
				<p class="text-2xl font-semibold">Package not found</p>
				<p class="text-black/50 dark:text-white/50">
					<code class="font-mono text-sm">{name}</code> doesn't exist
					in the registry.
				</p>
			</div>
		);
	}

	const installCmd = `lde add ${name}`;
	const repoName = git
		.replace(/\.git$/, "")
		.replace(/\/$/, "")
		.split("/")
		.slice(-2)
		.join("/");

	const treeNodes = tree ? buildTree(tree) : [];

	// Recursively render a directory row followed by its children, each level
	// indented further so files nest under their containing folders.
	const renderTreeNode = (
		node: TreeNode,
		depth: number,
	): preact.JSX.Element[] => [
		<a
			key={node.path}
			href={treeLink(node)}
			target="_blank"
			rel="noopener noreferrer"
			class="flex items-center gap-2 px-3 py-1.5 hover:bg-black/[0.03] dark:hover:bg-white/[0.03] transition-colors"
			style={{ paddingLeft: `calc(0.75rem + ${depth * 16}px)` }}
		>
			{node.type === "tree" ? (
				<svg
					xmlns="http://www.w3.org/2000/svg"
					aria-hidden="true"
					class="size-3.5 shrink-0 text-blue-500/70"
					viewBox="0 0 24 24"
					fill="none"
					stroke="currentColor"
					stroke-width="2"
					stroke-linecap="round"
					stroke-linejoin="round"
				>
					<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z" />
				</svg>
			) : (
				<svg
					xmlns="http://www.w3.org/2000/svg"
					aria-hidden="true"
					class="size-3.5 shrink-0 text-black/35 dark:text-white/30"
					viewBox="0 0 24 24"
					fill="none"
					stroke="currentColor"
					stroke-width="2"
					stroke-linecap="round"
					stroke-linejoin="round"
				>
					<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z" />
					<path d="M14 2v4a2 2 0 0 0 2 2h4" />
				</svg>
			)}
			<span class="font-mono text-xs truncate">
				{node.path.split("/").pop()}
			</span>
			{node.type === "blob" && node.size != null && (
				<span class="ml-auto pl-3 text-[11px] text-black/30 dark:text-white/30 shrink-0">
					{formatSize(node.size)}
				</span>
			)}
		</a>,
		...(node.type === "tree"
			? node.children.flatMap((child) => renderTreeNode(child, depth + 1))
			: []),
	];

	const treeLink = (node: GitTreeNode) =>
		repo
			? repoWebUrl(
					repo,
					treeRef,
					node.path,
					node.type === "tree" ? "tree" : "blob",
			  )
			: "";

	return (
		<div class="flex flex-col gap-8">
			{/* Header */}
			<div class="flex flex-col gap-3">
				<h1 class="text-3xl font-bold flex items-baseline gap-3">
					{name}
					{latest && (
						<span class="text-gray-500 dark:text-gray-400 font-medium">
							v{latest}
						</span>
					)}
				</h1>

				{description && (
					<p class="text-black/60 dark:text-white/60 leading-relaxed">
						{description}
					</p>
				)}
			</div>

			{/* Body: tabs + sidebar */}
			<div class="flex flex-col lg:flex-row gap-10">
				{/* Main content */}
				<div class="flex-1 min-w-0">
					{/* Tab bar */}
					<div
						class="flex border-b border-black/10 dark:border-white/10"
						role="tablist"
					>
						{TABS.map((t) => (
							<button
								key={t.id}
								type="button"
								role="tab"
								aria-selected={tab === t.id}
								onClick={() => setTab(t.id)}
								class={`-mb-px border-b-2 px-4 py-2.5 text-sm font-medium transition-colors cursor-pointer ${
									tab === t.id
										? "border-blue-600 text-black dark:text-white"
										: "border-transparent text-black/45 dark:text-white/40 hover:text-black dark:hover:text-white"
								}`}
							>
								{t.label}
							</button>
						))}
					</div>

					{/* Overview */}
					{tab === "overview" && (
						<div class="pt-6">
							{readmeUrl && (readme || readmeLoading) ? (
								readmeLoading ? (
									<div class="h-32 animate-pulse bg-black/5 dark:bg-white/5" />
								) : (
									<div class="border border-black/10 dark:border-white/10 bg-black/[0.02] dark:bg-white/[0.02] px-6 py-5">
										<div
											class="markdown readme"
											dangerouslySetInnerHTML={{ __html: readmeHtml ?? "" }}
										/>
									</div>
								)
							) : (
								<p class="text-sm text-black/40 dark:text-white/40">
									No README found for this package.
								</p>
							)}
						</div>
					)}

					{/* Versions */}
					{tab === "versions" && (
						<div class="pt-6">
							{versions === null ? (
								<p class="text-sm text-black/30 dark:text-white/30">
									Loading…
								</p>
							) : versions.length === 0 ? (
								<p class="text-sm text-black/30 dark:text-white/30">
									No versions published.
								</p>
							) : (
								<div class="flex flex-col divide-y divide-black/8 dark:divide-white/8 border border-black/10 dark:border-white/10">
									{versions.map(([version, commit]) => (
										<div
											key={version}
											class="flex items-center justify-between px-4 py-3 bg-black/[0.01] dark:bg-white/[0.01]"
										>
											<div class="flex items-center gap-3">
												<span class="font-mono text-sm font-medium">
													v{version}
												</span>
												{version === latest && (
													<span class="text-[10px] font-medium px-1.5 py-0.5 bg-green-500/10 text-green-500 border border-green-500/20">
														latest
													</span>
												)}
											</div>
											<a
												href={`${git.replace(/\.git$/, "")}/commit/${commit}`}
												target="_blank"
												rel="noopener noreferrer"
												class="font-mono text-xs text-black/30 dark:text-white/30 hover:text-blue-500 transition-colors"
											>
												{commit.slice(0, 7)}
											</a>
										</div>
									))}
								</div>
							)}
						</div>
					)}

					{/* Files */}
					{tab === "files" && (
						<div class="pt-6">
							{!repo ? (
								<p class="text-sm text-black/40 dark:text-white/40">
									File browsing is only available for GitHub-, GitLab-,
									Codeberg-, and Bitbucket-hosted packages.
								</p>
							) : treeLoading ? (
								<div class="h-32 animate-pulse bg-black/5 dark:bg-white/5" />
							) : treeError ? (
								<p class="text-sm text-red-600/80 dark:text-red-400/80">
									{treeError}
								</p>
							) : treeNodes.length > 0 ? (
								<div class="border border-black/10 dark:border-white/10 divide-y divide-black/5 dark:divide-white/5 max-h-[28rem] overflow-y-auto">
									{treeNodes.flatMap((node) => renderTreeNode(node, 0))}
								</div>
							) : (
								<p class="text-sm text-black/40 dark:text-white/40">
									This repository has no files.
								</p>
							)}
						</div>
					)}
				</div>

				{/* Sidebar */}
				<aside class="lg:w-56 shrink-0 flex flex-col gap-6">
					{/* Install */}
					<div class="flex flex-col gap-2">
						<h2 class="text-sm font-semibold text-black/40 dark:text-white/40">
							Install
						</h2>
						<div class="flex items-center gap-2 bg-black/5 dark:bg-white/5 border border-black/10 dark:border-white/10 px-3 py-2">
							<code class="text-xs font-mono flex-1 break-all">
								{installCmd}
							</code>
							<CopyButton getText={() => installCmd} />
						</div>
					</div>

					{/* Metadata */}
					{(authors.length > 0 || license || lastUpdated) && (
						<div class="flex flex-col gap-3">
							{authors.length > 0 && (
								<div class="flex flex-col gap-1">
									<h2 class="text-sm font-semibold text-black/40 dark:text-white/40">
										Authors
									</h2>
									<p class="text-sm">
										{authors.map((a, i) => {
											const { name, email } =
												parseAuthor(a);
											return (
												<span key={i}>
													{i > 0 && ", "}
													{email ? (
														<a
															href={`mailto:${email}`}
															class="text-blue-500 hover:underline"
														>
															{name}
														</a>
													) : (
														name
													)}
												</span>
											);
										})}
									</p>
								</div>
							)}
							{license && (
								<div class="flex flex-col gap-1">
									<h2 class="text-sm font-semibold text-black/40 dark:text-white/40">
										License
									</h2>
									<p class="text-sm font-mono">{license}</p>
								</div>
							)}
							{lastUpdated && (
								<div class="flex flex-col gap-1">
									<h2 class="text-sm font-semibold text-black/40 dark:text-white/40">
										Updated
									</h2>
									<p class="text-sm">
										{formatDate(lastUpdated)}
									</p>
								</div>
							)}
						</div>
					)}

					{/* Repository */}
					{git && (
						<div class="flex flex-col gap-2">
							<h2 class="text-sm font-semibold text-black/40 dark:text-white/40">
								Repository
							</h2>
							<a
								href={git}
								target="_blank"
								rel="noopener noreferrer"
								class="inline-flex items-center gap-2 text-sm text-blue-500 hover:underline"
							>
								<svg
									xmlns="http://www.w3.org/2000/svg"
									aria-hidden="true"
									class="size-4 shrink-0"
									viewBox="0 0 24 24"
									fill="currentColor"
								>
									<path d="M12 0C5.37 0 0 5.37 0 12c0 5.3 3.44 9.8 8.21 11.39.6.11.82-.26.82-.58v-2.03c-3.34.73-4.04-1.61-4.04-1.61-.55-1.39-1.34-1.76-1.34-1.76-1.09-.74.08-.73.08-.73 1.2.08 1.84 1.24 1.84 1.24 1.07 1.83 2.81 1.3 3.49 1 .11-.78.42-1.3.76-1.6-2.67-.3-5.47-1.33-5.47-5.93 0-1.31.47-2.38 1.24-3.22-.13-.3-.54-1.52.12-3.18 0 0 1.01-.32 3.3 1.23a11.5 11.5 0 0 1 3-.4c1.02 0 2.04.14 3 .4 2.29-1.55 3.3-1.23 3.3-1.23.66 1.66.25 2.88.12 3.18.77.84 1.24 1.91 1.24 3.22 0 4.61-2.81 5.63-5.48 5.92.43.37.81 1.1.81 2.22v3.29c0 .32.22.7.83.58C20.57 21.8 24 17.3 24 12c0-6.63-5.37-12-12-12z" />
								</svg>
								{repoName}
							</a>
						</div>
					)}

					{/* Dependencies */}
					{deps && deps.length > 0 && (
						<div class="flex flex-col gap-2">
							<h2 class="text-sm font-semibold text-black/40 dark:text-white/40">
								Dependencies
							</h2>
							<div class="flex flex-wrap gap-2">
								{deps.map(([depName, version]) => (
									<a
										key={depName}
										href={`/registry/${depName}/`}
										class="inline-flex items-center gap-1.5 px-2.5 py-1 text-xs font-mono border border-black/10 dark:border-white/10 bg-black/5 dark:bg-white/5 hover:border-blue-600/40 hover:text-blue-500 transition-colors"
									>
										{depName}
										<span class="text-black/30 dark:text-white/30">
											{version}
										</span>
									</a>
								))}
							</div>
						</div>
					)}
				</aside>
			</div>
		</div>
	);
}
