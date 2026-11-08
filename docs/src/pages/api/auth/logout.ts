import type { APIContext } from "astro";
import { clearGithubSession, json } from "../../../lib/server/github";

export const prerender = false;

export async function POST(context: APIContext) {
	await clearGithubSession(context);
	return json({ ok: true });
}
