/**
 * Locating a package inside its repository.
 *
 * A package's manifest can live anywhere in the tree — lde's own resolver
 * scans for it rather than assuming a layout (lde-core's `util.findNamedPackage`)
 * — so the repo root is only a guess. The registry portfile pins a commit and
 * knows the package name, so matching that name against the manifests in the
 * commit's tree gives the package's real directory, which is what the README
 * and everything relative to it resolve against.
 */

/** A file or directory entry from a host's tree API. */
export interface TreeEntry {
	path: string;
	type: "blob" | "tree";
}

/** Manifest filenames, in preference order: lde.json, then the pre-rename name. */
const MANIFEST_NAMES = ["lde.json", "lpm.json"];

/** Directory holding a repo-relative path ("" when it sits at the repo root). */
export function dirOf(path: string): string {
	const slash = path.lastIndexOf("/");
	return slash === -1 ? "" : path.slice(0, slash);
}

/**
 * Joins a path onto a repo-relative directory, collapsing "." and ".." so a
 * README in a subdirectory resolves its relative links to URLs the hosts can
 * actually serve — raw file endpoints do not normalize paths for us.
 */
export function joinRepoPath(dir: string, path: string): string {
	const parts = dir === "" ? [] : dir.split("/");
	for (const segment of path.split("/")) {
		if (segment === "" || segment === ".") continue;
		if (segment === "..") {
			parts.pop();
			continue;
		}
		parts.push(segment);
	}
	return parts.join("/");
}

/**
 * Reads the package name out of a manifest. lde accepts JSON5 manifests, so a
 * strict parse can fail on a file that publishes perfectly well — fall back to
 * reading the top-level name directly in that case.
 */
export function manifestName(src: string | null): string | null {
	if (!src) return null;
	try {
		const parsed: unknown = JSON.parse(src);
		if (parsed && typeof parsed === "object" && "name" in parsed) {
			const name = (parsed as { name?: unknown }).name;
			return typeof name === "string" ? name : null;
		}
	} catch {
		// JSON5 allows bare identifier keys, so the quotes are optional here.
		const match = src.match(/(?:^|[{,])\s*["']?name["']?\s*:\s*["']([^"']+)["']/m);
		if (match) return match[1] ?? null;
	}
	return null;
}

/**
 * Manifest paths that could belong to `packageName`, best candidate first: a
 * directory named after the package (packages/datastar for tltp/datastar),
 * then the shallowest, then alphabetical so the order is deterministic.
 */
export function rankManifests(
	entries: TreeEntry[],
	packageName: string,
): string[] {
	const wanted = packageName.split("/").pop()?.toLowerCase() ?? "";

	const score = (path: string) => {
		const dir = dirOf(path).split("/").pop()?.toLowerCase() ?? "";
		return dir === wanted ? 0 : 1;
	};

	return entries
		.filter(
			(entry) =>
				entry.type === "blob" &&
				MANIFEST_NAMES.includes(
					entry.path.split("/").pop()?.toLowerCase() ?? "",
				),
		)
		.map((entry) => entry.path)
		.sort(
			(a, b) =>
				score(a) - score(b) ||
				a.split("/").length - b.split("/").length ||
				a.localeCompare(b),
		);
}

export interface PackageDirLookup {
	/** Package name as the registry knows it, e.g. "tltp/datastar". */
	packageName: string;
	/** Raw manifest at a repo-relative path, or null when it isn't there. */
	readManifest: (path: string) => Promise<string | null>;
	/** The commit's file tree. */
	readTree: () => Promise<TreeEntry[]>;
}

/**
 * Repo-relative directory of a package, or "" for the repo root.
 *
 * The root manifest is probed first: a flat repo answers with a single raw
 * read and never spends the host's rate-limited tree API quota. Anything else
 * falls through to the tree, where the manifest matching the package name
 * wins — the same rule lde itself applies. A layout that matches nothing
 * resolves to the repo root, which is what this page assumed before monorepos
 * were handled at all.
 */
export async function resolvePackageDir(
	lookup: PackageDirLookup,
): Promise<string> {
	if (manifestName(await lookup.readManifest("lde.json")) === lookup.packageName) {
		return "";
	}

	const entries = await lookup.readTree();
	for (const path of rankManifests(entries, lookup.packageName)) {
		if (manifestName(await lookup.readManifest(path)) === lookup.packageName) {
			return dirOf(path);
		}
	}

	return "";
}
