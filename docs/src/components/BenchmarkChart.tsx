import { useState, useEffect, useRef } from "preact/hooks";

const benchmarks = [
	{
		name: "Busted (Cold)",
		results: [
			{ tool: "lde", time: 0.746 },
			{ tool: "luarocks", time: 8.251 },
			{ tool: "lx", time: 2.950 },
		],
	},
	{
		name: "Busted (Warm)",
		results: [
			{ tool: "lde", time: 0.008 },
			{ tool: "luarocks", time: 1.196 },
			{ tool: "lx", time: 2.297 },
		],
	},
	{
		name: "LuaFileSystem",
		results: [
			{ tool: "lde", time: 0.312 },
			{ tool: "luarocks", time: 0.757 },
			{ tool: "lx", time: 1.096 },
		],
	},
];

const COLORS: Record<string, { bar: string; text: string; label: string }> = {
	lde:      { bar: "bg-blue-500",                     text: "text-blue-500 dark:text-blue-400",   label: "text-white/80" },
	luarocks: { bar: "bg-slate-300/70 dark:bg-slate-500",  text: "text-slate-500 dark:text-slate-500", label: "text-black/50 dark:text-white/80" },
	lx:       { bar: "bg-slate-200/80 dark:bg-slate-600",  text: "text-slate-500 dark:text-slate-500", label: "text-black/50 dark:text-white/80" },
};



export default function BenchmarkChart() {
	const [current, setCurrent] = useState(0);
	// "idle" | "reset" | "playing"
	const [phase, setPhase] = useState<"idle" | "reset" | "playing">("idle");
	const ref = useRef<HTMLDivElement>(null);

	const bench = benchmarks[current];
	const sorted = [...bench.results].sort((a, b) => a.time - b.time);
	const max = sorted[sorted.length - 1].time;
	const fastest = sorted[0];

	// Trigger on scroll into view
	useEffect(() => {
		const observer = new IntersectionObserver(
			([entry]) => { if (entry.isIntersecting) setPhase("playing"); },
			{ threshold: 0.2 },
		);
		if (ref.current) observer.observe(ref.current);
		return () => observer.disconnect();
	}, []);

	// On tab change: snap to 0, then play
	function switchTab(i: number) {
		if (i === current) return;
		setCurrent(i);
		setPhase("reset");
	}

	useEffect(() => {
		if (phase !== "reset") return;
		const id = requestAnimationFrame(() => setPhase("playing"));
		return () => cancelAnimationFrame(id);
	}, [phase, current]);

	return (
		<div ref={ref} class="rounded-2xl border border-black/10 dark:border-white/10 overflow-hidden">
			{/* Header with tabs */}
			<div class="flex items-center justify-between px-4 sm:px-6 pt-5 pb-0 border-b border-black/8 dark:border-white/8">
				<div class="flex gap-0.5 sm:gap-1">
					{benchmarks.map((b, i) => (
						<button
							key={i}
							type="button"
							onClick={() => switchTab(i)}
							class={`px-2 sm:px-3 py-2 cursor-pointer transition-colors text-xs sm:text-sm rounded-t-lg border-b-2 -mb-px font-medium whitespace-nowrap ${
								i === current
									? "border-blue-500 text-black dark:text-white"
									: "border-transparent text-black/40 dark:text-white/35 hover:text-black/70 dark:hover:text-white/60"
							}`}
						>
							{b.name}
						</button>
					))}
				</div>
				<a
					href="https://github.com/lde-org/lde/tree/master/benchmarks"
					class="hidden sm:flex text-xs text-black/30 dark:text-white/25 hover:text-black/60 dark:hover:text-white/50 transition-colors pb-3 items-center gap-1"
					target="_blank" rel="noopener noreferrer"
				>
					View source
					<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7 7h10v10"/><path d="M7 17 17 7"/></svg>
				</a>
			</div>

			{/* Chart body */}
			<div class="p-6 space-y-5 bg-black/[0.015] dark:bg-white/[0.015]">
				{sorted.map((r, rank) => {
					const c = COLORS[r.tool] ?? COLORS.lx;
					const pct = (r.time / max) * 100;
					const duration = Math.max(r.time * 1000, 150);
					const multiplier = r.time / fastest.time;
					const isLde = r.tool === "lde";
					const isFastest = rank === 0;
					const playing = phase === "playing";

					return (
						<div key={r.tool} class="space-y-2">
							<div class="flex items-center justify-between text-sm">
								<div class="flex items-center gap-2">
									{isLde
										? <img src="/lde-nospace.svg" class="h-4 -mt-0.5" alt="" />
										: <span class={`font-medium ${c.text}`}>{r.tool}</span>
									}
									{isLde && <span class={`font-semibold ${c.text}`}>lde</span>}
									{isFastest && (
										<span class="text-[10px] font-semibold uppercase tracking-wider text-emerald-400 bg-emerald-400/10 border border-emerald-400/20 px-1.5 py-0.5 rounded-full">
											fastest
										</span>
									)}
									{!isFastest && isLde && (
										<a href="https://github.com/lde-org/lde/issues/102" target="_blank" rel="noopener noreferrer" class="text-xs opacity-50 hover:opacity-80 transition-opacity" title="tracking issue">😞</a>
									)}
								</div>
								<div class="flex items-center gap-3">
									{!isFastest && (
										<span class="text-xs text-black/30 dark:text-white/25 font-mono">
											{multiplier.toFixed(1)}× slower
										</span>
									)}
									<span class={`font-mono text-sm font-semibold ${c.text}`}>
										{r.time.toFixed(3)}s
									</span>
								</div>
							</div>

							{/* Bar track */}
							<div class="h-7 rounded-lg bg-black/5 dark:bg-white/5 overflow-hidden relative">
								<div
									class={`h-full rounded-lg flex items-center justify-end pr-2 ${c.bar}`}
									style={{
										width: playing ? `${pct}%` : "0%",
										transition: playing ? `width ${duration}ms ease-out` : "none",
									}}
								>
									{playing && (
										<span class={`text-xs font-semibold whitespace-nowrap ${c.label}`}>
											{r.time.toFixed(3)}s
										</span>
									)}
								</div>
								{[25, 50, 75].map(p => (
									<div
										key={p}
										class="absolute top-0 bottom-0 w-px bg-black/5 dark:bg-white/5"
										style={{ left: `${p}%` }}
									/>
								))}
							</div>
						</div>
					);
				})}
			</div>

			{/* Footer */}
			<div class="px-6 py-3 border-t border-black/8 dark:border-white/8 flex items-center justify-between gap-2 text-xs text-black/30 dark:text-white/25">
				<div class="flex items-center gap-2">
					<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/></svg>
					Linux x86-64 · 4 cores · avg of 5 runs · latest versions
				</div>
				<a
					href="https://github.com/lde-org/lde/tree/master/benchmarks"
					class="sm:hidden flex items-center gap-1 hover:text-black/60 dark:hover:text-white/50 transition-colors"
					target="_blank" rel="noopener noreferrer"
				>
					View source
					<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7 7h10v10"/><path d="M7 17 17 7"/></svg>
				</a>
			</div>
		</div>
	);
}
