import { useState, useEffect, useRef, useCallback } from "preact/hooks";
import { createPortal } from "preact/compat";

interface DocEntry {
	title: string;
	url: string;
	type: "doc" | "blog";
	body: string;
}

function highlight(text: string, query: string): string {
	if (!query) return text;
	const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	return text.replace(new RegExp(`(${escaped})`, "gi"), "<mark>$1</mark>");
}

function search(index: DocEntry[], query: string): DocEntry[] {
	if (!query.trim()) return [];
	const q = query.toLowerCase();
	const scored = index.flatMap((doc) => {
		const titleMatch = doc.title.toLowerCase().includes(q);
		const bodyIdx = doc.body.toLowerCase().indexOf(q);
		if (!titleMatch && bodyIdx === -1) return [];
		return [{ doc, titleMatch, bodyIdx }];
	});
	scored.sort((a, b) => {
		if (a.titleMatch !== b.titleMatch) return a.titleMatch ? -1 : 1;
		return 0;
	});
	return scored.slice(0, 8).map((s) => s.doc);
}

function getSnippet(body: string, query: string): string {
	const idx = body.toLowerCase().indexOf(query.toLowerCase());
	if (idx === -1) return body.slice(0, 120) + (body.length > 120 ? "…" : "");
	const start = Math.max(0, idx - 40);
	const end = Math.min(body.length, idx + query.length + 80);
	return (start > 0 ? "…" : "") + body.slice(start, end) + (end < body.length ? "…" : "");
}

export default function Search() {
	const [open, setOpen] = useState(false);
	const [query, setQuery] = useState("");
	const [index, setIndex] = useState<DocEntry[]>([]);
	const [activeIdx, setActiveIdx] = useState(0);
	const inputRef = useRef<HTMLInputElement>(null);
	const listRef = useRef<HTMLUListElement>(null);

	// Fetch index once when modal opens
	useEffect(() => {
		if (open && index.length === 0) {
			fetch("/search-index.json")
				.then((r) => r.json())
				.then(setIndex);
		}
	}, [open]);

	// Focus input when opened
	useEffect(() => {
		if (open) {
			setTimeout(() => inputRef.current?.focus(), 10);
			setQuery("");
			setActiveIdx(0);
		}
	}, [open]);

	// Keyboard shortcut to open: Cmd/Ctrl+K
	useEffect(() => {
		const handler = (e: KeyboardEvent) => {
			if ((e.metaKey || e.ctrlKey) && e.key === "k") {
				e.preventDefault();
				setOpen((o) => !o);
			}
			if (e.key === "Escape") setOpen(false);
		};
		window.addEventListener("keydown", handler);
		return () => window.removeEventListener("keydown", handler);
	}, []);

	const results = search(index, query);

	const navigate = useCallback(
		(url: string) => {
			window.location.href = url;
			setOpen(false);
		},
		[],
	);

	const handleKeyDown = (e: KeyboardEvent) => {
		if (e.key === "ArrowDown") {
			e.preventDefault();
			setActiveIdx((i) => Math.min(i + 1, results.length - 1));
		} else if (e.key === "ArrowUp") {
			e.preventDefault();
			setActiveIdx((i) => Math.max(i - 1, 0));
		} else if (e.key === "Enter" && results[activeIdx]) {
			navigate(results[activeIdx].url);
		}
	};

	// Reset active index when results change
	useEffect(() => setActiveIdx(0), [query]);

	// Scroll active result into view
	useEffect(() => {
		const el = listRef.current?.children[activeIdx] as HTMLElement | undefined;
		el?.scrollIntoView({ block: "nearest" });
	}, [activeIdx]);

	return (
		<>
			<button
				onClick={() => setOpen(true)}
				class="flex items-center gap-2 px-3.5 py-2 border border-black/20 dark:border-white/20 bg-black/5 dark:bg-white/5 hover:bg-black/10 dark:hover:bg-white/10 transition text-sm text-black/70 dark:text-white/60 cursor-pointer"
			>
				<svg xmlns="http://www.w3.org/2000/svg" class="size-4 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
					<circle cx="11" cy="11" r="8" /><line x1="21" y1="21" x2="16.65" y2="16.65" />
				</svg>
				<span class="hidden sm:inline">Search</span>
				<kbd class="hidden sm:inline-flex items-center gap-0.5 px-1.5 py-0.5 border border-black/20 dark:border-white/20 text-xs font-mono leading-none">
					<span class="text-[10px]">⌘</span>K
				</kbd>
			</button>

			{open &&
				createPortal(
					<div
						class="fixed inset-0 z-50 flex items-start justify-center pt-[15vh] px-4"
						onClick={(e) => e.target === e.currentTarget && setOpen(false)}
					>
					{/* Backdrop */}
					<div class="absolute inset-0 bg-black/20 dark:bg-black/30" onClick={() => setOpen(false)} />

					{/* Modal */}
					<div class="relative w-full max-w-lg bg-gray-950 shadow-2xl border border-white/10 overflow-hidden">
						<div class="flex items-center gap-3 px-4 border-b border-white/8">
							<svg xmlns="http://www.w3.org/2000/svg" class="size-4 shrink-0 text-white/30" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
								<circle cx="11" cy="11" r="8" /><line x1="21" y1="21" x2="16.65" y2="16.65" />
							</svg>
							<input
								ref={inputRef}
								type="text"
								placeholder="Search docs..."
								value={query}
								onInput={(e) => setQuery((e.target as HTMLInputElement).value)}
								onKeyDown={handleKeyDown}
								class="w-full py-4 bg-transparent outline-none text-sm text-white placeholder:text-white/25"
							/>
							<kbd
								class="shrink-0 px-1.5 py-0.5 rounded border border-white/15 text-xs font-mono text-white/30 cursor-pointer"
								onClick={() => setOpen(false)}
							>
								Esc
							</kbd>
						</div>

						{query && (
							<ul ref={listRef} class="max-h-80 overflow-y-auto py-2">
								{results.length === 0 ? (
									<li class="px-4 py-8 text-center text-sm text-white/30">
										No results for "{query}"
									</li>
								) : (
									results.map((doc, i) => (
										<li key={doc.url}>
											<button
												class={`w-full text-left px-4 py-3 transition ${
													i === activeIdx
														? "bg-blue-500/10"
														: "hover:bg-white/5"
												}`}
												onClick={() => navigate(doc.url)}
												onMouseEnter={() => setActiveIdx(i)}
											>
												<div class="flex items-center gap-2">
													<span
														class="text-sm font-medium text-white/85"
														dangerouslySetInnerHTML={{ __html: highlight(doc.title, query) }}
													/>
													<span class={`text-[10px] font-medium px-1.5 py-0.5 rounded ${doc.type === "blog" ? "bg-purple-500/10 text-purple-400" : "bg-blue-500/10 text-blue-400"}`}>
														{doc.type}
													</span>
												</div>
												<div
													class="text-xs text-white/35 mt-0.5 line-clamp-2"
													dangerouslySetInnerHTML={{
														__html: highlight(getSnippet(doc.body, query), query),
													}}
												/>
											</button>
										</li>
									))
								)}
							</ul>
						)}

						{!query && (
							<p class="px-4 py-8 text-center text-sm text-white/25">
								Type to search…
							</p>
						)}
					</div>
					</div>,
					document.body,
				)}

			<style>{`
				mark {
					background: transparent;
					color: rgb(59 130 246);
					font-weight: 600;
				}
			`}</style>
		</>
	);
}
