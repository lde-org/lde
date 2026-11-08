import type { APIContext } from "astro";
import {
	exchangeCode,
	hasGithubConfig,
	json,
	setGithubSession,
	takeOAuthState,
} from "../../../lib/server/github";

export const prerender = false;

export async function GET(context: APIContext) {
	if (!hasGithubConfig(context)) {
		return json(
			{ error: "GitHub login is not configured on this deployment." },
			503,
		);
	}
	if (!context.session) {
		return json({ error: "Sessions are unavailable on this deployment." }, 503);
	}

	const code = context.url.searchParams.get("code");
	const state = context.url.searchParams.get("state");
	const expected = await takeOAuthState(context);

	if (!code || !state || !expected || state !== expected) {
		return json({ error: "Invalid or expired OAuth state." }, 400);
	}

	try {
		const returnTo = await context.session.get("returnTo");
		const session = await exchangeCode(context, code);
		await context.session.regenerate();
		await setGithubSession(context, session);
		return context.redirect(returnTo ?? "/registry");
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : "GitHub login failed." },
			400,
		);
	}
}
