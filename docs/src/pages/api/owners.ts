import type { APIContext } from "astro";
import {
	assertSameOrigin,
	createFilePullRequest,
	getGithubSession,
	getRegistryBranch,
	getRegistryRepo,
	githubRequest,
	json,
} from "../../lib/server/github";
import {
	isAdmin,
	normalizeAuthority,
	ownerInfos,
	ownerKey,
	ownersFor,
	readAuthority,
	sortedObject,
	validateNamespace,
	validatePackage,
} from "../../lib/server/registry";

export const prerender = false;

interface Scope {
	kind: "package" | "namespace";
	name: string;
}

function scopeFromQuery(context: APIContext): Scope {
	const namespace = context.url.searchParams.get("namespace");
	if (namespace) return { kind: "namespace", name: validateNamespace(namespace) };
	return { kind: "package", name: validatePackage(context.url.searchParams.get("package")) };
}

function scopeFromBody(value: { package?: unknown; namespace?: unknown }): Scope {
	if (typeof value.namespace === "string") {
		return { kind: "namespace", name: validateNamespace(value.namespace) };
	}
	return { kind: "package", name: validatePackage(value.package) };
}

export async function GET(context: APIContext) {
	try {
		const scope = scopeFromQuery(context);
		const repo = getRegistryRepo(context);
		const branch = getRegistryBranch(context);
		const authority = await readAuthority(repo, branch);
		const ids = scope.kind === "namespace"
			? authority.namespaces[scope.name] ?? []
			: ownersFor(authority, scope.name);
		const session = await getGithubSession(context);
		const owners = await ownerInfos(ids, session?.accessToken, new Map());
		const canEdit = session
			? ids.includes(session.user.id) ||
				(await isAdmin(context, session.accessToken, session.user.login))
			: false;
		return json({ scope, owners, canEdit });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : "Owner lookup failed." },
			400,
		);
	}
}

export async function POST(context: APIContext) {
	try {
		assertSameOrigin(context);
		const session = await getGithubSession(context);
		if (!session) return json({ error: "Sign in with GitHub first." }, 401);

		const body = (await context.request.json()) as {
			package?: unknown;
			namespace?: unknown;
			login?: unknown;
		};
		const scope = scopeFromBody(body);
		const login =
			typeof body.login === "string" ? body.login.trim().replace(/^@/, "") : "";
		if (!/^[A-Za-z0-9-]{1,39}$/.test(login)) {
			return json({ error: "Enter a valid GitHub username." }, 400);
		}

		const repo = getRegistryRepo(context);
		const branch = getRegistryBranch(context);
		const authority = await readAuthority(repo, branch);
		const key = scope.kind === "namespace"
			? { map: "namespaces" as const, key: scope.name }
			: ownerKey(scope.name);
		const current = authority[key.map][key.key] ?? [];

		if (!current.includes(session.user.id)) {
			if (!(await isAdmin(context, session.accessToken, session.user.login))) {
				return json({ error: `You do not own ${scope.name}.` }, 403);
			}
		}

		const target = await githubRequest<{ id: number; login: string }>(
			session.accessToken,
			`/users/${login}`,
		);
		if (current.includes(target.id)) {
			return json({ error: `@${target.login} is already an owner.` }, 409);
		}

		authority[key.map][key.key] = [...current, target.id];
		const content = `${JSON.stringify(
			{
				namespaces: sortedObject(authority.namespaces),
				top: sortedObject(authority.top),
			},
			null,
			"\t",
		)}\n`;
		const pr = await createFilePullRequest({
			token: session.accessToken,
			repo,
			path: "authority.json",
			content,
			branch: `owners/${scope.name.replace(/\//g, "-")}-${Date.now()}`,
			title: `Add @${target.login} as an owner of ${scope.name}`,
			body: [
				`<!-- lde-owners -->`,
				`Add @${target.login} (id ${target.id}) as an owner of \`${scope.name}\`.`,
				"",
				`Requested by @${session.user.login} (id ${session.user.id}).`,
				"",
				"Only owner additions are allowed in this pull request.",
			].join("\n"),
		});
		return json({ url: pr.html_url, number: pr.number }, 201);
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : "Owner update failed." },
			400,
		);
	}
}
