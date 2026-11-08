import type { APIContext } from "astro";
import { getGithubSession, getRegistryBranch, getRegistryRepo, json } from "../../../lib/server/github";
import {
	ownerInfos,
	ownersFor,
	readAuthority,
	readIndex,
	readPortfile,
	type Authority,
	type IndexEntry,
	type OwnerInfo,
} from "../../../lib/server/registry";

export const prerender = false;

interface ManagedPackage {
	name: string;
	namespace: string | null;
	versions: string[];
	revoked: string[];
	latest: string | null;
	owners: OwnerInfo[];
	git: string | null;
}

interface ManagedNamespace {
	name: string;
	owners: OwnerInfo[];
	packages: string[];
}

export async function GET(context: APIContext) {
	try {
		const session = await getGithubSession(context);
		if (!session) return json({ error: "Sign in with GitHub first." }, 401);

		const repo = getRegistryRepo(context);
		const branch = getRegistryBranch(context);
		const authority = await readAuthority(repo, branch);
		const index = await readIndex(repo);
		const indexByName = new Map(index.map((entry) => [entry.name, entry]));
		const loginCache = new Map<number, Promise<string | null>>();

		const flatNames = Object.keys(authority.top).filter((name) =>
			ownersFor(authority, name).includes(session.user.id),
		);
		const namespaceNames = Object.keys(authority.namespaces).filter((name) =>
			authority.namespaces[name].includes(session.user.id),
		);
		const namespacePackageNames = namespaceNames.flatMap((namespace) =>
			index
				.filter((entry) => entry.name.startsWith(`${namespace}/`))
				.map((entry) => entry.name),
		);

		const names = [...new Set([...flatNames, ...namespacePackageNames])];
		const packages: ManagedPackage[] = await Promise.all(
			names.map(async (name) => {
				const portfile = await readPortfile(repo, branch, name);
				const entry = indexByName.get(name);
				const owners = ownersFor(authority, name);
				return {
					name,
					namespace: name.includes("/") ? name.split("/")[0] ?? null : null,
					versions: Object.keys(portfile?.versions ?? {}),
					revoked: portfile?.revoked ?? [],
					latest: entry?.latest ?? null,
					owners: await ownerInfos(owners, session.accessToken, loginCache),
					git: portfile?.git ?? entry?.git ?? null,
				};
			}),
		);

		const namespaces: ManagedNamespace[] = await Promise.all(
			namespaceNames.map(async (name) => ({
				name,
				owners: await ownerInfos(
					authority.namespaces[name] ?? [],
					session.accessToken,
					loginCache,
				),
				packages: index
					.filter((entry) => entry.name.startsWith(`${name}/`))
					.map((entry) => entry.name),
			})),
		);

		return json({ user: session.user, packages, namespaces });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : "Could not load registry." },
			400,
		);
	}
}
