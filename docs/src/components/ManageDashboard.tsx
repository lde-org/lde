import { useEffect, useState } from "preact/hooks";
import OwnerManager from "./OwnerManager";

interface Owner {
	id: number;
	login: string | null;
}

interface ManagedPackage {
	name: string;
	namespace: string | null;
	versions: string[];
	revoked: string[];
	latest: string | null;
	owners: Owner[];
	git: string | null;
}

interface ManagedNamespace {
	name: string;
	owners: Owner[];
	packages: string[];
}

interface ManageData {
	user: {
		login: string;
		id: number;
	};
	packages: ManagedPackage[];
	namespaces: ManagedNamespace[];
}

function PackageCard({ pkg }: { pkg: ManagedPackage }) {
	const [version, setVersion] = useState("");
	const [file, setFile] = useState<File | null>(null);
	const [busy, setBusy] = useState(false);
	const [message, setMessage] = useState<string | null>(null);
	const [error, setError] = useState<string | null>(null);
	const canUpload = Boolean(pkg.git?.includes("github.com"));

	const revoke = async (target: string) => {
		if (!window.confirm(`Revoke ${pkg.name}@${target}?`)) return;
		setBusy(true);
		setError(null);
		try {
			const response = await fetch("/api/revoke", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ package: pkg.name, version: target }),
			});
			const data = (await response.json()) as { url?: string; error?: string };
			if (!response.ok || !data.url) throw new Error(data.error ?? "Revoke failed.");
			setMessage(`Revocation requested: ${data.url}`);
		} catch (revokeError) {
			setError(revokeError instanceof Error ? revokeError.message : "Revoke failed.");
		} finally {
			setBusy(false);
		}
	};

	const upload = async () => {
		if (!file || !version.trim()) return;
		setBusy(true);
		setError(null);
		try {
			const form = new FormData();
			form.set("package", pkg.name);
			form.set("version", version.trim());
			form.set("file", file);
			const response = await fetch("/api/upload", { method: "POST", body: form });
			const data = (await response.json()) as { url?: string; error?: string };
			if (!response.ok || !data.url) throw new Error(data.error ?? "Upload failed.");
			setMessage(`Upload requested: ${data.url}`);
			setFile(null);
			setVersion("");
		} catch (uploadError) {
			setError(uploadError instanceof Error ? uploadError.message : "Upload failed.");
		} finally {
			setBusy(false);
		}
	};

	return (
		<div class="border border-black/10 dark:border-white/10 bg-black/[0.02] dark:bg-white/[0.02] p-5 flex flex-col gap-4">
			<div class="flex flex-wrap items-baseline justify-between gap-2">
				<a href={`/registry/${pkg.name}`} class="text-lg font-semibold hover:text-blue-500">
					{pkg.name}
				</a>
				<span class="text-xs font-mono text-black/40 dark:text-white/40">
					{pkg.latest ? `latest v${pkg.latest}` : "no published version"}
				</span>
			</div>

			<div class="flex flex-wrap gap-1.5">
				{pkg.versions.map((candidate) => {
					const isRevoked = pkg.revoked.includes(candidate);
					return (
						<span
							key={candidate}
							class={`inline-flex items-center gap-1.5 px-2 py-0.5 text-[11px] font-mono border ${
								isRevoked
									? "border-red-500/20 text-red-500 line-through"
									: "border-black/10 dark:border-white/10 text-black/60 dark:text-white/60"
							}`}
						>
							v{candidate}
							{!isRevoked && (
								<button
									type="button"
									onClick={() => revoke(candidate)}
									disabled={busy}
									class="cursor-pointer text-[10px] text-red-500/70 hover:text-red-500"
								>
									revoke
								</button>
							)}
						</span>
					);
				})}
			</div>

			<OwnerManager packageName={pkg.name} />

			{canUpload ? (
			<div class="border-t border-black/5 dark:border-white/5 pt-3 flex flex-col gap-2">
				<h3 class="text-sm font-semibold text-black/40 dark:text-white/40">
					Upload a tarball
				</h3>
				<div class="flex flex-wrap items-center gap-2">
					<input
						type="text"
						value={version}
						onInput={(event) => setVersion((event.target as HTMLInputElement).value)}
						placeholder="1.0.0"
						class="w-28 px-2 py-1.5 text-xs font-mono border border-black/10 dark:border-white/15 bg-black/5 dark:bg-white/5 outline-none focus:border-blue-500/60"
					/>
					<input
						type="file"
						accept=".tar.gz,.tgz,.tar.bz2,.tbz2,.tar.xz,.txz,.zip"
						onChange={(event) =>
							setFile((event.target as HTMLInputElement).files?.[0] ?? null)
						}
						class="min-w-0 text-xs text-black/50 dark:text-white/50 file:mr-2 file:px-2 file:py-1 file:border-0 file:bg-black/5 dark:file:bg-white/10 file:text-xs"
					/>
					<button
						type="button"
						onClick={upload}
						disabled={busy || !file || !version.trim()}
						class="cursor-pointer px-3 py-1.5 text-xs font-medium bg-blue-600 text-white hover:bg-blue-500 transition disabled:opacity-40"
					>
						{busy ? "Working…" : "Upload"}
					</button>
				</div>
				<p class="text-[11px] text-black/35 dark:text-white/35">
					Uploads to a GitHub release in the package repository, then opens a registry PR.
				</p>
				{message && <p class="text-xs text-green-600 dark:text-green-400">{message}</p>}
				{error && <p class="text-xs text-red-500">{error}</p>}
			</div>
			) : (
				<p class="text-[11px] text-black/35 dark:text-white/35">
					Tarball uploads require a GitHub package repository. Publish this version from the CLI with --archive instead.
				</p>
			)}
		</div>
	);
}

export default function ManageDashboard({ user }: { user: ManageData["user"] }) {
	const [data, setData] = useState<ManageData | null>(null);
	const [error, setError] = useState<string | null>(null);
	const [namespace, setNamespace] = useState("");
	const [requesting, setRequesting] = useState(false);
	const [requestUrl, setRequestUrl] = useState<string | null>(null);

	useEffect(() => {
		fetch("/api/manage")
			.then(async (response) => {
				if (response.status === 401) {
					window.location.href = "/api/auth/login?returnTo=/registry/manage";
					return null;
				}
				const body = (await response.json()) as ManageData & { error?: string };
				if (!response.ok) throw new Error(body.error ?? "Could not load registry.");
				return body;
			})
			.then((body) => {
				if (body) setData(body);
			})
			.catch((loadError) =>
				setError(loadError instanceof Error ? loadError.message : "Could not load registry."),
			);
	}, []);

	useEffect(() => {
		if (!data) return;
		const intent = new URLSearchParams(window.location.search).get("intent");
		const target = intent === "claim" ? "namespaces" : intent === "publish" ? "packages" : null;
		if (target) document.getElementById(target)?.scrollIntoView({ behavior: "smooth" });
	}, [data]);

	const requestNamespace = async () => {
		if (!namespace.trim() || requesting) return;
		setRequesting(true);
		setError(null);
		try {
			const response = await fetch("/api/namespaces/request", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ namespace: namespace.trim() }),
			});
			const body = (await response.json()) as { url?: string; error?: string };
			if (!response.ok || !body.url) throw new Error(body.error ?? "Request failed.");
			setRequestUrl(body.url);
			setNamespace("");
		} catch (requestError) {
			setError(requestError instanceof Error ? requestError.message : "Request failed.");
		} finally {
			setRequesting(false);
		}
	};

	const signOut = async () => {
		await fetch("/api/auth/logout", { method: "POST" });
		window.location.href = "/registry";
	};

	return (
		<div class="px-4 md:px-6 py-12 max-w-5xl mx-auto w-full flex flex-col gap-10">
			<div class="flex flex-wrap items-start justify-between gap-4">
				<div>
					<h1 class="text-3xl font-bold tracking-tight">Manage registry</h1>
					<p class="mt-2 text-sm text-black/50 dark:text-white/50">
						Signed in as <span class="font-mono">@{user.login}</span>.
					</p>
				</div>
				<button
					type="button"
					onClick={signOut}
					class="cursor-pointer text-xs text-black/40 dark:text-white/40 hover:text-red-500"
				>
					Sign out
				</button>
			</div>

			{error && <p class="text-sm text-red-500">{error}</p>}

			<section id="packages" class="flex flex-col gap-4">
				<h2 class="text-xl font-semibold">Your packages</h2>
				{!data ? (
					<p class="text-sm text-black/40 dark:text-white/40">Loading…</p>
				) : data.packages.length === 0 ? (
					<p class="text-sm text-black/40 dark:text-white/40">
						No packages yet. Publish one from the CLI, then manage it here.
					</p>
				) : (
					data.packages.map((pkg) => <PackageCard key={pkg.name} pkg={pkg} />)
				)}
			</section>

			<section id="namespaces" class="flex flex-col gap-4">
				<h2 class="text-xl font-semibold">Namespaces</h2>
				{!data ? null : data.namespaces.length === 0 ? (
					<p class="text-sm text-black/40 dark:text-white/40">
						You do not own a namespace yet.
					</p>
				) : (
					data.namespaces.map((ns) => (
						<div
							key={ns.name}
							class="border border-black/10 dark:border-white/10 p-5 flex flex-col gap-3"
						>
							<div class="flex flex-wrap items-baseline justify-between gap-2">
								<h3 class="font-semibold">{ns.name}</h3>
								<span class="text-xs text-black/40 dark:text-white/40">
									{ns.packages.length} package{ns.packages.length === 1 ? "" : "s"}
								</span>
							</div>
							<OwnerManager namespace={ns.name} />
							{ns.packages.length > 0 && (
								<div class="flex flex-wrap gap-2 text-xs">
									{ns.packages.map((packageName) => (
										<a
											key={packageName}
											href={`/registry/${packageName}`}
											class="text-blue-500 hover:underline font-mono"
										>
											{packageName}
										</a>
									))}
								</div>
							)}
						</div>
					))
				)}

				<div class="border-t border-black/5 dark:border-white/5 pt-4 flex flex-col gap-2">
					<h3 class="text-sm font-semibold text-black/40 dark:text-white/40">
						Request a namespace
					</h3>
					<div class="flex flex-wrap items-center gap-2">
						<input
							type="text"
							value={namespace}
							onInput={(event) => setNamespace((event.target as HTMLInputElement).value)}
							placeholder="your-namespace"
							class="w-56 px-2 py-1.5 text-xs border border-black/10 dark:border-white/15 bg-black/5 dark:bg-white/5 outline-none focus:border-blue-500/60"
						/>
						<button
							type="button"
							onClick={requestNamespace}
							disabled={requesting || !namespace.trim()}
							class="cursor-pointer px-3 py-1.5 text-xs font-medium bg-blue-600 text-white hover:bg-blue-500 transition disabled:opacity-40"
						>
							{requesting ? "Requesting…" : "Request"}
						</button>
					</div>
					<p class="text-[11px] text-black/35 dark:text-white/35">
						A moderator must approve the request.
					</p>
					{requestUrl && (
						<p class="text-xs text-green-600 dark:text-green-400">
							Requested:{" "}
							<a href={requestUrl} target="_blank" rel="noopener noreferrer" class="underline">
								open issue
							</a>
						</p>
					)}
				</div>
			</section>
		</div>
	);
}
