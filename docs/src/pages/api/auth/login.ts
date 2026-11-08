import type { APIContext } from "astro";
import {
	authorizeUrl,
	createOAuthState,
	getEnv,
	json,
	setOAuthState,
} from "../../../lib/server/github";

export const prerender = false;

export async function GET(context: APIContext) {
	const env = getEnv(context);
	if (!env.GITHUB_CLIENT_ID || !env.GITHUB_CLIENT_SECRET) {
		return json(
			{ error: "GitHub login is not configured on this deployment." },
			503,
		);
	}
	if (!context.session) {
		return json({ error: "Sessions are unavailable on this deployment." }, 503);
	}

	const returnTo = context.url.searchParams.get("returnTo");
	if (returnTo && returnTo.startsWith("/") && !returnTo.startsWith("//")) {
		await context.session.set("returnTo", returnTo);
	}

	const state = createOAuthState();
	await setOAuthState(context, state);
	return context.redirect(authorizeUrl(context, state));
}
