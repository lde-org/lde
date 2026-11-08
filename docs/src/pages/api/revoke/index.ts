import type { APIContext } from "astro";
import {
	assertSameOrigin,
	createFilePullRequest,
	getGithubSession,
	getRegistryBranch,
	getRegistryRepo,
	json,
} from "../../../lib/server/github";
import {
	isAdmin,
	isOwner,
	readAuthority,
	readPortfile,
	validatePackage,
} from "../../../lib/server/registry";

export const prerender = false;

const VERSION_RE = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;

export async function POST(context: APIContext) {
	try {
		assertSameOrigin(context);
		const session = await getGithubSession(context);
		if (!session) return json({ error: "Sign in with GitHub first." }, 401);
		if (!session.user.twoFactorAuthentication) {
			return json(
				{ error: "Enable two-factor authentication on GitHub before revoking versions." },
				403,
			);
		}

		const body = (await context.request.json()) as {
			package?: unknown;
			version?: unknown;
		};
		const name = validatePackage(body.package);
		const version = typeof body.version === "string" ? body.version : "";
		if (!VERSION_RE.test(version)) {
			return json({ error: "Enter a valid version." }, 400);
		}

		const repo = getRegistryRepo(context);
		const branch = getRegistryBranch(context);
		const authority = await readAuthority(repo, branch);
		if (
			!isOwner(authority, name, session.user.id) &&
			!(await isAdmin(context, session.accessToken, session.user.login))
		) {
			return json({ error: `You do not own ${name}.` }, 403);
		}

		const portfile = await readPortfile(repo, branch, name);
		if (!portfile) return json({ error: `Package ${name} was not found.` }, 404);
		if (!portfile.versions || portfile.versions[version] === undefined) {
			return json({ error: `Version ${version} was not found.` }, 404);
		}
		const revoked = Array.isArray(portfile.revoked) ? [...portfile.revoked] : [];
		if (revoked.includes(version)) {
			return json({ error: `Version ${version} is already revoked.` }, 409);
		}
		revoked.push(version);

		const updated = { ...portfile, revoked };
		const content = `${JSON.stringify(updated, null, "\t")}\n`;
		const pr = await createFilePullRequest({
			token: session.accessToken,
			repo,
			path: `packages/${name}.json`,
			content,
			branch: `revoke/${name.replace(/\//g, "-")}-${version}-${Date.now()}`,
			title: `Revoke ${name}@${version}`,
			body: [
				"<!-- lde-revoke -->",
				`Revoke \`${name}@${version}\`.`,
				"",
				`Requested by @${session.user.login} (id ${session.user.id}).`,
				"",
				"The version entry and its source stay untouched; only the `revoked` list changes.",
			].join("\n"),
		});
		return json({ url: pr.html_url, number: pr.number }, 201);
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : "Revocation failed." },
			400,
		);
	}
}
