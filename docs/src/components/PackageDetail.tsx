import { useState, useEffect, useMemo } from "preact/hooks";
import { Marked } from "marked";
import DOMPurify from "dompurify";
import { CopyButton } from "./CopyButton";
import { usePortfile } from "../hooks/usePortfile";
import { useRegistry } from "../hooks/useRegistry";

// Fetch with a localStorage cache: returns cached data when fresh, otherwise
// fetches and stores the result. Used for the README and GitHub tree fetches
// so repeat visits don't re-hit the network (or the GitHub API rate limit).
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

interface GitHubRepo {
	owner: string;
	repo: string;
}

function githubRepo(git: string): GitHubRepo | null {
	const m = git.replace(/\.git$/, "").match(
		/^https?:\/\/github\.com\/([^/]+)\/([^/]+)/,
	);
	if (!m) return null;
	return { owner: m[1], repo: m[2] };
}

// Resolve a raw README.md URL for a GitHub-hosted package, pinned to the
// given commit (or the default branch when no commit is known).
function githubReadmeUrl(git: string, commit: string | null): string | null {
	const repo = githubRepo(git);
	if (!repo) return null;
	return `https://raw.githubusercontent.com/${repo.owner}/${repo.repo}/${
		commit ?? "HEAD"
	}/README.md`;
}

// Rewrite a relative README image path to its raw GitHub URL at the pinned
// ref. Absolute URLs, anchors, and data: URIs are left untouched.
function resolveAssetUrl(
	href: string,
	repo: GitHubRepo | null,
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
	return `https://raw.githubusercontent.com/${repo.owner}/${repo.repo}/${ref}/${clean}`;
}

// Rewrite a relative README link to its GitHub blob URL at the pinned ref.
function resolveLinkUrl(
	href: string,
	repo: GitHubRepo | null,
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
	return `https://github.com/${repo.owner}/${repo.repo}/blob/${ref}/${clean}`;
}

// Render a README with marked (GFM) and sanitize the result, then resolve
// relative image and link URLs against the package's GitHub URLs at the
// pinned ref so they work outside the repo page.
function renderReadme(
	src: string,
	repo: GitHubRepo | null,
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
	const readmeUrl = githubReadmeUrl(git, latestCommit);
	const repo = githubRepo(git);
	const treeRef = latestCommit ?? portfile?.branch ?? "HEAD";

	// Try to resolve a README.md from the package's GitHub repo at the
	// pinned commit of the latest version (falling back to the default branch).
	// Cached locally — the content is immutable per commit, so it's held for a day.
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

	// Fetch the full file tree of the latest commit via the GitHub API.
	// Only fetched once the Files tab is opened, and cached locally for 15
	// minutes to stay well under the unauthenticated rate limit.
	useEffect(() => {
		setTree(null);
		setTreeLoading(false);
		setTreeError(null);
		if (tab !== "files" || !repo) return;
		setTreeLoading(true);
		const url = `https://api.github.com/repos/${repo.owner}/${repo.repo}/git/trees/${treeRef}?recursive=1`;
		cachedFetch<{ tree?: GitTreeNode[]; truncated?: boolean }>(
			`lde-tree:${repo.owner}/${repo.repo}/${treeRef}`,
			url,
			15 * 60 * 1000,
			(r) => r.json(),
		)
			.then((data) => {
				if (!data) {
					setTreeError("GitHub API request failed");
					setTreeLoading(false);
					return;
				}
				// Huge repos get truncated — keep only the top two levels
				// so the listing stays usable.
				const nodes = data.tree ?? [];
				setTree(
					data.truncated
						? nodes.filter((n) => n.path.split("/").length <= 2)
						: nodes,
				);
				setTreeLoading(false);
			})
			.catch((e: Error) => {
				setTreeError(e.message);
				setTreeLoading(false);
			});
	}, [tab, repo?.owner, repo?.repo, treeRef]);

	// Rendered README HTML — memoized so marked only re-parses when the
	// source or the pinned ref changes.
	const readmeHtml = useMemo(
		() => (readme ? renderReadme(readme, repo, treeRef) : null),
		[readme, repo?.owner, repo?.repo, treeRef],
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

	// Sorted tree: directories first, then files, both alphabetically.
	const displayTree = (tree ?? [])
		.map((n) => ({ ...n, depth: n.path.split("/").length - 1 }))
		.sort((a, b) => {
			if (a.type !== b.type) return a.type === "tree" ? -1 : 1;
			return a.path.localeCompare(b.path);
		});

	const treeLink = (node: GitTreeNode) =>
		`https://github.com/${repo?.owner}/${repo?.repo}/${
			node.type === "tree" ? "tree" : "blob"
		}/${treeRef}/${node.path}`;

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
									File browsing is only available for
									GitHub-hosted packages.
								</p>
							) : treeLoading ? (
								<div class="h-32 animate-pulse bg-black/5 dark:bg-white/5" />
							) : treeError ? (
								<p class="text-sm text-red-600/80 dark:text-red-400/80">
									{treeError}
								</p>
							) : displayTree.length > 0 ? (
								<div class="border border-black/10 dark:border-white/10 divide-y divide-black/5 dark:divide-white/5 max-h-[28rem] overflow-y-auto">
									{displayTree.map((node) => (
										<a
											key={node.path}
											href={treeLink(node)}
											target="_blank"
											rel="noopener noreferrer"
											class="flex items-center gap-2 px-3 py-1.5 hover:bg-black/[0.03] dark:hover:bg-white/[0.03] transition-colors"
											style={{
												paddingLeft: `calc(0.75rem + ${node.depth * 16}px)`,
											}}
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
											{node.type === "blob" &&
												node.size != null && (
													<span class="ml-auto pl-3 text-[11px] text-black/30 dark:text-white/30 shrink-0">
														{formatSize(node.size)}
													</span>
												)}
										</a>
									))}
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
