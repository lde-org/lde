import type { APIContext } from "astro";
import {
	assertSameOrigin,
	getGithubSession,
	getRegistryRepo,
	githubRequest,
	json,
} from "../../../lib/server/github";

export const prerender = false;

const NAMESPACE_RE = /^[a-z][a-z0-9_-]{1,}[a-z0-9]$/;

interface Issue {
	number: number;
	html_url: string;
}

export async function POST(context: APIContext) {
	try {
		assertSameOrigin(context);
		const session = await getGithubSession(context);
		if (!session) {
			return json({ error: "Sign in with GitHub first." }, 401);
		}
		if (!session.user.twoFactorAuthentication) {
			return json(
				{ error: "Enable two-factor authentication on GitHub before requesting a namespace." },
				403,
			);
		}

		const last = await context.session?.get("lastNamespaceRequest");
		if (last && Date.now() - last < 30_000) {
			return json({ error: "Wait a moment before requesting another namespace." }, 429);
		}

		const body = (await context.request.json()) as { namespace?: unknown };
		const namespace =
			typeof body.namespace === "string" ? body.namespace.trim() : "";
		if (
			namespace.length < 3 ||
			namespace.length > 128 ||
			!NAMESPACE_RE.test(namespace)
		) {
			return json(
				{
					error:
						"Namespaces must be 3-128 chars, lowercase, start with a letter, end with a letter or digit, and contain only a-z, 0-9, _ and -.",
				},
				400,
			);
		}

		const repo = getRegistryRepo(context);
		const issue = await githubRequest<Issue>(
			session.accessToken,
			`/repos/${repo}/issues`,
			{
				method: "POST",
				body: JSON.stringify({
					title: `Namespace request: ${namespace}`,
					body: `/request-namespace ${namespace}\n\nRequested via https://lde.sh/registry/claim by @${session.user.login}.`,
				}),
			},
		);

		await context.session?.set("lastNamespaceRequest", Date.now());
		return json({ url: issue.html_url, number: issue.number }, 201);
	} catch (error) {
		const message =
			error instanceof Error ? error.message : "Namespace request failed.";
		return json({ error: message }, 400);
	}
}
