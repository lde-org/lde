import type { APIContext } from "astro";
import {
	assertSameOrigin,
	createFilePullRequest,
	getGithubSession,
	getRegistryBranch,
	getRegistryRepo,
	githubRequest,
	json,
} from "../../../lib/server/github";
import {
	isAdmin,
	isOwner,
	parseGitHubRepo,
	readAuthority,
	readPortfile,
	validatePackage,
} from "../../../lib/server/registry";

export const prerender = false;

const VERSION_RE = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;
const MAX_BYTES = 50 * 1024 * 1024;
const ARCHIVE_RE = /\.(?:tar\.gz|tgz|tar\.bz2|tbz2|tar\.xz|txz|zip)$/i;

function hex(buffer: ArrayBuffer): string {
	return Array.from(new Uint8Array(buffer))
		.map((byte) => byte.toString(16).padStart(2, "0"))
		.join("");
}

async function sha256(buffer: ArrayBuffer): Promise<string> {
	return hex(await crypto.subtle.digest("SHA-256", buffer));
}

interface Release {
	id: number;
	tag_name: string;
}

interface Asset {
	browser_download_url: string;
}

export async function POST(context: APIContext) {
	try {
		assertSameOrigin(context);
		const session = await getGithubSession(context);
		if (!session) return json({ error: "Sign in with GitHub first." }, 401);
		if (!session.user.twoFactorAuthentication) {
			return json(
				{ error: "Enable two-factor authentication on GitHub before uploading a tarball." },
				403,
			);
		}

		const form = await context.request.formData();
		const name = validatePackage(form.get("package"));
		const version = String(form.get("version") ?? "");
		const file = form.get("file");
		if (!VERSION_RE.test(version)) {
			return json({ error: "Enter a valid version." }, 400);
		}
		if (!(file instanceof File) || file.size === 0) {
			return json({ error: "Choose a tarball to upload." }, 400);
		}
		if (file.size > MAX_BYTES) {
			return json({ error: "Tarballs are limited to 50 MiB." }, 413);
		}
		if (!ARCHIVE_RE.test(file.name)) {
			return json({ error: "Upload a .tar.gz, .tgz, .tar.bz2, .tar.xz or .zip archive." }, 400);
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
		if (portfile.versions?.[version] !== undefined) {
			return json({ error: `Version ${version} already exists.` }, 409);
		}
		const source = parseGitHubRepo(portfile.git);
		if (!source) {
			return json(
				{ error: "Uploads require a GitHub package repository. Use an archive URL for other hosts." },
				400,
			);
		}

		const buffer = await file.arrayBuffer();
		const hash = await sha256(buffer);
		const tag = `lde-${version}`;
		let release: Release;
		try {
			release = await githubRequest<Release>(
				session.accessToken,
				`/repos/${source.owner}/${source.repo}/releases`,
				{
					method: "POST",
					body: JSON.stringify({
						tag_name: tag,
						name: tag,
						draft: false,
						prerelease: false,
						generate_release_notes: false,
					}),
				},
			);
		} catch {
			release = await githubRequest<Release>(
				session.accessToken,
				`/repos/${source.owner}/${source.repo}/releases/tags/${tag}`,
			);
		}

		const assetName = `${file.name.replace(/[^A-Za-z0-9._-]/g, "-")}-${Date.now()}`;
		const assetResponse = await fetch(
			`https://uploads.github.com/repos/${source.owner}/${source.repo}/releases/${release.id}/assets?name=${encodeURIComponent(assetName)}`,
			{
				method: "POST",
				headers: {
					Accept: "application/vnd.github+json",
					Authorization: `Bearer ${session.accessToken}`,
					"Content-Type": "application/octet-stream",
					"User-Agent": "lde-website",
					"X-GitHub-Api-Version": "2022-11-28",
				},
				body: buffer,
			},
		);
		if (!assetResponse.ok) {
			const message = (await assetResponse.json().catch(() => null)) as
				| { message?: string }
				| null;
			throw new Error(message?.message ?? `GitHub asset upload failed (${assetResponse.status}).`);
		}
		const asset = (await assetResponse.json()) as Asset;

		const versions = { ...(portfile.versions ?? {}), [version]: {
			archive: asset.browser_download_url,
			sha256: hash,
			size: file.size,
		} };
		const content = `${JSON.stringify({ ...portfile, versions }, null, "\t")}\n`;
		const pr = await createFilePullRequest({
			token: session.accessToken,
			repo,
			path: `packages/${name}.json`,
			content,
			branch: `upload/${name.replace(/\//g, "-")}-${version}-${Date.now()}`,
			title: `Publish ${name}@${version} from a tarball`,
			body: [
				"<!-- lde-upload -->",
				`Publish \`${name}@${version}\` from a tarball.`,
				"",
				`- Asset: ${asset.browser_download_url}`,
				`- SHA-256: \`${hash}\``,
				`- Size: ${file.size} bytes`,
				"",
				`Uploaded by @${session.user.login} (id ${session.user.id}).`,
			].join("\n"),
		});
		return json({ url: pr.html_url, number: pr.number, sha256: hash }, 201);
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : "Upload failed." },
			400,
		);
	}
}
