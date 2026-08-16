import { useEffect, useRef, useState } from "preact/hooks";

// Mirrors the registry's namespace rules (see the namespace-request workflow):
// 3-128 chars, lowercase, starts with a letter, ends with a letter or digit,
// only a-z, 0-9, _ and -.
const NAMESPACE_RE = /^[a-z][a-z0-9_-]{1,}[a-z0-9]$/;

// Raw authority file; claimed namespaces live in its `namespaces` map. Fetched
// once on mount and cached in state, so the availability check never refetches
// per keystroke.
const AUTHORITY_URL =
	"https://raw.githubusercontent.com/lde-org/registry/master/authority.json";

export default function ClaimNamespace() {
	const [nsInput, setNsInput] = useState("");
	const [nsClaimed, setNsClaimed] = useState<Set<string> | null>(null);
	const [nsAuthorityLoading, setNsAuthorityLoading] = useState(false);
	const [nsAuthorityError, setNsAuthorityError] = useState<string | null>(null);
	const nsInputRef = useRef<HTMLInputElement>(null);

	// Load the authority file once up front and keep it in state; the
	// availability check below only consults the cached copy.
	useEffect(() => {
		let cancelled = false;
		setNsAuthorityLoading(true);
		fetch(AUTHORITY_URL)
			.then((r) => {
				if (!r.ok) throw new Error(`HTTP ${r.status}`);
				return r.json();
			})
			.then((data: { namespaces?: Record<string, unknown> }) => {
				if (!cancelled) {
					setNsClaimed(new Set(Object.keys(data.namespaces ?? {})));
				}
			})
			.catch((e) => {
				if (!cancelled) {
					setNsAuthorityError(e instanceof Error ? e.message : String(e));
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
		nsFormatValid && !nsTaken && nsClaimed !== null && !nsAuthorityLoading;

	const loadAuthority = () => {
		setNsAuthorityLoading(true);
		setNsAuthorityError(null);
		fetch(AUTHORITY_URL)
			.then((r) => {
				if (!r.ok) throw new Error(`HTTP ${r.status}`);
				return r.json();
			})
			.then((data: { namespaces?: Record<string, unknown> }) => {
				setNsClaimed(new Set(Object.keys(data.namespaces ?? {})));
			})
			.catch((e) => setNsAuthorityError(e instanceof Error ? e.message : String(e)))
			.finally(() => setNsAuthorityLoading(false));
	};

	// Submits by opening a GitHub issue whose body contains the machine phrase
	// the registry bot listens for. New tab so the claim page stays loaded.
	const submitNamespaceRequest = () => {
		if (!nsCanSubmit) return;
		const title = `Namespace request: ${nsInput}`;
		const body = `/request-namespace ${nsInput}\n\nThis pull request was generated via the lde website.`;
		window.open(
			`https://github.com/lde-org/registry/issues/new?title=${encodeURIComponent(title)}&body=${encodeURIComponent(body)}`,
			"_blank",
			"noopener,noreferrer",
		);
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
				onInput={(e) => setNsInput((e.target as HTMLInputElement).value)}
				placeholder="your-namespace"
				maxLength={128}
				class="w-full max-w-sm px-3 py-2.5 text-sm border border-black/15 dark:border-white/15 bg-black/5 dark:bg-white/5 outline-none focus:border-blue-600/60 focus:ring-2 focus:ring-blue-600/20 transition placeholder:text-black/30 dark:placeholder:text-white/30"
			/>
			{/* Fixed-height hint area so the button below never jumps between states. */}
			<div class="mt-2 h-8 text-xs">
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
			</div>
			<button
				type="button"
				onClick={submitNamespaceRequest}
				disabled={!nsCanSubmit}
				class="inline-flex cursor-pointer items-center gap-2 px-5 py-2.5 text-sm font-medium bg-blue-600 text-white hover:bg-blue-500 transition disabled:opacity-40 disabled:pointer-events-none"
			>
				<svg
					aria-hidden="true"
					xmlns="http://www.w3.org/2000/svg"
					class="size-4"
					viewBox="0 0 24 24"
					fill="none"
					stroke="currentColor"
					stroke-width="2"
					stroke-linecap="round"
					stroke-linejoin="round"
				>
					<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z" />
				</svg>
				Request namespace
			</button>
		</div>
	);
}
