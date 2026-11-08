import { useEffect, useRef, useState } from "preact/hooks";
import { useAuth } from "../hooks/useAuth";

// Mirrors the registry's namespace rules (see src/namespace-request.lua):
// 3-128 chars, lowercase, starts with a letter, ends with a letter or digit,
// only a-z, 0-9, _ and -.
const NAMESPACE_RE = /^[a-z][a-z0-9_-]{1,}[a-z0-9]$/;

const AUTHORITY_URL =
	"https://raw.githubusercontent.com/lde-org/registry/master/authority.json";

interface RequestResult {
	url: string;
	number: number;
}

export default function ClaimNamespace() {
	const { user, loading: authLoading } = useAuth();
	const [nsInput, setNsInput] = useState("");
	const [nsClaimed, setNsClaimed] = useState<Set<string> | null>(null);
	const [nsAuthorityLoading, setNsAuthorityLoading] = useState(false);
	const [nsAuthorityError, setNsAuthorityError] = useState<string | null>(null);
	const [requesting, setRequesting] = useState(false);
	const [requestError, setRequestError] = useState<string | null>(null);
	const [requestResult, setRequestResult] = useState<RequestResult | null>(null);
	const nsInputRef = useRef<HTMLInputElement>(null);

	useEffect(() => {
		if (!authLoading && !user) {
			window.location.href = "/api/auth/login?returnTo=/registry/claim";
		}
	}, [authLoading, user]);

	useEffect(() => {
		let cancelled = false;
		setNsAuthorityLoading(true);
		fetch(AUTHORITY_URL)
			.then((response) => {
				if (!response.ok) throw new Error(`HTTP ${response.status}`);
				return response.json();
			})
			.then((data: { namespaces?: Record<string, unknown> }) => {
				if (!cancelled) {
					setNsClaimed(new Set(Object.keys(data.namespaces ?? {})));
				}
			})
			.catch((error) => {
				if (!cancelled) {
					setNsAuthorityError(
						error instanceof Error ? error.message : String(error),
					);
				}
			})
			.finally(() => {
				if (!cancelled) setNsAuthorityLoading(false);
			});
		nsInputRef.current?.focus();
		return () => {
			cancelled = true;
		};
	}, []);

	const nsFormatValid =
		nsInput.length >= 3 && nsInput.length <= 128 && NAMESPACE_RE.test(nsInput);
	const nsTaken = nsFormatValid && nsClaimed?.has(nsInput);
	const nsCanSubmit =
		nsFormatValid &&
		!nsTaken &&
		nsClaimed !== null &&
		!nsAuthorityLoading &&
		!requesting &&
		!requestResult;

	const loadAuthority = () => {
		setNsAuthorityLoading(true);
		setNsAuthorityError(null);
		fetch(AUTHORITY_URL)
			.then((response) => {
				if (!response.ok) throw new Error(`HTTP ${response.status}`);
				return response.json();
			})
			.then((data: { namespaces?: Record<string, unknown> }) => {
				setNsClaimed(new Set(Object.keys(data.namespaces ?? {})));
			})
			.catch((error) =>
				setNsAuthorityError(
					error instanceof Error ? error.message : String(error),
				),
			)
			.finally(() => setNsAuthorityLoading(false));
	};

	const submitNamespaceRequest = async () => {
		if (!nsCanSubmit || !user) return;
		setRequesting(true);
		setRequestError(null);
		try {
			const response = await fetch("/api/namespaces/request", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ namespace: nsInput }),
			});
			const data = (await response.json()) as RequestResult & { error?: string };
			if (!response.ok) {
				throw new Error(data.error ?? `Request failed (${response.status})`);
			}
			setRequestResult(data);
		} catch (error) {
			setRequestError(
				error instanceof Error ? error.message : "Namespace request failed.",
			);
		} finally {
			setRequesting(false);
		}
	};

	return (
		<div>
			<label for="namespace-input" class="block text-sm font-medium mb-1.5">
				Namespace name
			</label>
			<input
				id="namespace-input"
				ref={nsInputRef}
				type="text"
				value={nsInput}
				onInput={(event) =>
					setNsInput((event.target as HTMLInputElement).value)
				}
				placeholder="your-namespace"
				maxLength={128}
				class="w-full max-w-sm px-3 py-2.5 text-sm border border-black/15 dark:border-white/15 bg-black/5 dark:bg-white/5 outline-none focus:border-blue-600/60 focus:ring-2 focus:ring-blue-600/20 transition placeholder:text-black/30 dark:placeholder:text-white/30"
			/>
			<div class="mt-2 min-h-8 text-xs">
				{nsInput !== "" && !nsFormatValid && (
					<p class="text-red-500 line-clamp-2">
						Must be 3-128 chars, lowercase, start with a letter, end with a
						letter or digit (a-z, 0-9, _ and -).
					</p>
				)}
				{nsFormatValid && nsAuthorityLoading && (
					<p class="text-black/40 dark:text-white/40 line-clamp-2">
						Checking availability…
					</p>
				)}
				{nsFormatValid && nsAuthorityError && (
					<p class="text-red-500 line-clamp-2">
						Couldn't verify availability ({nsAuthorityError}).
						<button
							type="button"
							onClick={loadAuthority}
							class="cursor-pointer underline underline-offset-2 ml-1"
						>
							Retry
						</button>
					</p>
				)}
				{nsFormatValid && nsClaimed?.has(nsInput) && (
					<p class="text-red-500 line-clamp-2">This namespace is already claimed.</p>
				)}
				{nsFormatValid && nsClaimed !== null && !nsClaimed?.has(nsInput) && (
					<p class="text-green-600 dark:text-green-400 line-clamp-2">Available.</p>
				)}
				{requestError && (
					<p class="text-red-500 line-clamp-2">{requestError}</p>
				)}
				{requestResult && (
					<p class="text-green-600 dark:text-green-400 line-clamp-2">
						Requested.{" "}
						<a
							href={requestResult.url}
							target="_blank"
							rel="noopener noreferrer"
							class="underline underline-offset-2"
						>
							Open issue #{requestResult.number}
						</a>{" "}
						— a moderator must approve it.
					</p>
				)}
			</div>
			<button
				type="button"
				onClick={submitNamespaceRequest}
				disabled={!nsCanSubmit || authLoading || !user}
				class="inline-flex cursor-pointer items-center gap-2 px-5 py-2.5 text-sm font-medium bg-blue-600 text-white hover:bg-blue-500 transition disabled:opacity-40 disabled:pointer-events-none"
			>
				{requesting ? "Requesting…" : "Request namespace"}
			</button>
			{authLoading && (
				<p class="mt-3 text-xs text-black/40 dark:text-white/40">
					Checking your GitHub session…
				</p>
			)}
		</div>
	);
}
