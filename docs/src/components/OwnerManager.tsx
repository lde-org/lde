import { useEffect, useState } from "preact/hooks";

interface Owner {
	id: number;
	login: string | null;
}

interface OwnersResponse {
	owners?: Owner[];
	canEdit?: boolean;
	error?: string;
}

interface Props {
	packageName?: string;
	namespace?: string;
}

export default function OwnerManager({ packageName, namespace }: Props) {
	const [owners, setOwners] = useState<Owner[] | null>(null);
	const [canEdit, setCanEdit] = useState(false);
	const [error, setError] = useState<string | null>(null);
	const [login, setLogin] = useState("");
	const [submitting, setSubmitting] = useState(false);
	const [prUrl, setPrUrl] = useState<string | null>(null);

	const scopeName = namespace ?? packageName ?? "";
	const query = namespace
		? `namespace=${encodeURIComponent(namespace)}`
		: `package=${encodeURIComponent(packageName ?? "")}`;

	useEffect(() => {
		let cancelled = false;
		fetch(`/api/owners?${query}`)
			.then((response) => response.json() as Promise<OwnersResponse>)
			.then((data) => {
				if (cancelled) return;
				if (data.error) {
					setError(data.error);
					return;
				}
				setOwners(data.owners ?? []);
				setCanEdit(data.canEdit === true);
			})
			.catch(() => {
				if (!cancelled) setError("Could not load owners.");
			});
		return () => {
			cancelled = true;
		};
	}, [query]);

	const submit = async () => {
		if (!login.trim() || submitting) return;
		setSubmitting(true);
		setError(null);
		try {
			const response = await fetch("/api/owners", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify(
					namespace ? { namespace, login } : { package: packageName, login },
				),
			});
			const data = (await response.json()) as { url?: string; error?: string };
			if (!response.ok || !data.url) {
				throw new Error(data.error ?? "Owner update failed.");
			}
			setPrUrl(data.url);
			setLogin("");
		} catch (updateError) {
			setError(
				updateError instanceof Error ? updateError.message : "Owner update failed.",
			);
		} finally {
			setSubmitting(false);
		}
	};

	const label = namespace ? "Namespace owners" : "Owners";

	return (
		<div class="flex flex-col gap-2">
			<h3 class="text-sm font-semibold text-black/40 dark:text-white/40">{label}</h3>
			{owners === null ? (
				<p class="text-sm text-black/30 dark:text-white/30">Loading…</p>
			) : owners.length === 0 ? (
				<p class="text-sm text-black/40 dark:text-white/40">No recorded owner.</p>
			) : (
				<p class="text-sm flex flex-wrap gap-x-2 gap-y-1">
					{owners.map((owner) =>
						owner.login ? (
							<a
								key={owner.id}
								href={`https://github.com/${owner.login}`}
								target="_blank"
								rel="noopener noreferrer"
								class="text-blue-500 hover:underline"
							>
								@{owner.login}
							</a>
						) : (
							<span key={owner.id} class="font-mono text-xs">
								id {owner.id}
							</span>
						),
					)}
				</p>
			)}

			{canEdit && !prUrl && (
				<div class="flex flex-col gap-2">
					<div class="flex items-center gap-2">
						<input
							type="text"
							value={login}
							onInput={(event) =>
								setLogin((event.target as HTMLInputElement).value)
							}
							placeholder="GitHub username"
							class="min-w-0 flex-1 px-2 py-1.5 text-xs border border-black/10 dark:border-white/15 bg-black/5 dark:bg-white/5 outline-none focus:border-blue-500/60"
						/>
						<button
							type="button"
							onClick={submit}
							disabled={submitting || !login.trim()}
							class="cursor-pointer px-2.5 py-1.5 text-xs font-medium bg-blue-600 text-white hover:bg-blue-500 transition disabled:opacity-40"
						>
							{submitting ? "Adding…" : "Add owner"}
						</button>
					</div>
					<p class="text-[11px] text-black/35 dark:text-white/35">
						Opens a pull request for {scopeName}. A maintainer must merge it.
					</p>
				</div>
			)}

			{prUrl && (
				<p class="text-xs text-green-600 dark:text-green-400">
					Owner addition requested.{" "}
					<a
						href={prUrl}
						target="_blank"
						rel="noopener noreferrer"
						class="underline underline-offset-2"
					>
						Open pull request
					</a>
					.
				</p>
			)}
			{error && <p class="text-xs text-red-500">{error}</p>}
		</div>
	);
}
