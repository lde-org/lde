import type { APIContext } from "astro";
import { getGithubSession, json } from "../../../lib/server/github";

export const prerender = false;

export async function GET(context: APIContext) {
	const session = await getGithubSession(context);
	if (!session) return json({ authenticated: false, user: null });
	return json({ authenticated: true, user: session.user });
}
