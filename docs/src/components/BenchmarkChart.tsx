import { useState, useEffect, useRef } from "preact/hooks";

const benchmarks = [
	{
		name: "Busted (Cold)",
		results: [
			{ tool: "lde", time: 1.4 },
			{ tool: "luarocks", time: 4.307 },
			{ tool: "lx", time: 8.066 },
		],
	},
	{
		name: "Busted (Warm)",
		results: [
			{ tool: "lde", time: 0.134 },
			{ tool: "luarocks", time: 0.795 },
			{ tool: "lx", time: 2.284 },
		],
	},
	{
		name: "LuaFileSystem",
		results: [
			{ tool: "lde", time: 1.013 },
			{ tool: "luarocks", time: 0.438 },
			{ tool: "lx", time: 1.142 },
		],
	},
];

export default function BenchmarkChart() {
	const [current, setCurrent] = useState(0);
	const [animated, setAnimated] = useState(false);
	const ref = useRef<HTMLDivElement>(null);
	const bench = benchmarks[current];
	const sorted = [...bench.results].sort((a, b) => a.time - b.time);
	const max = sorted[sorted.length - 1].time;

	useEffect(() => {
		const observer = new IntersectionObserver(
			([entry]) => {
				if (entry.isIntersecting) setAnimated(true);
			},
			{ threshold: 0.3 },
		);
		if (ref.current) observer.observe(ref.current);
		return () => observer.disconnect();
	}, []);

	useEffect(() => {
		if (!animated) return;
		setAnimated(false);
		const id = requestAnimationFrame(() =>
			requestAnimationFrame(() => setAnimated(true)),
		);
		return () => cancelAnimationFrame(id);
	}, [current]);

	return (
		<div
			ref={ref}
			class="border border-gray-200 dark:border-gray-700 rounded-lg overflow-hidden"
		>
			{/* Tabs */}
			<div class="flex items-center border-b border-gray-200 dark:border-gray-700">
				{benchmarks.map((b, i) => (
					<button
						key={i}
						type="button"
						onClick={() => setCurrent(i)}
						class={`px-4 py-2 cursor-pointer transition-colors text-sm border-b-2 -mb-px ${
							i === current
								? "border-blue-500 text-gray-800 dark:text-gray-200"
								: "border-transparent text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200"
						}`}
					>
						{b.name}
					</button>
				))}
			</div>

			{/* Bars */}
			<div class="p-6 space-y-4 bg-gray-50 dark:bg-gray-900">
				{sorted.map((r, rank) => {
					const isLde = r.tool === "lde";
					return (
						<div key={r.tool}>
							<div class="flex justify-between text-sm mb-1.5">
								<span
									class={
										isLde
											? "font-semibold text-blue-500"
											: "text-gray-400 dark:text-gray-500"
									}
								>
									{isLde ? (
										<>
											<img
												src="/lde-nospace.svg"
												class="h-4 inline mr-1 -mt-0.5"
												alt=""
											/>
											lde
										</>
									) : (
										r.tool
									)}
								</span>
								<span
									class={`font-mono ${isLde ? "text-blue-500" : "text-gray-400 dark:text-gray-500"}`}
								>
									{r.time.toFixed(3)}s
									{rank === 0 && (
										<span class="text-green-500 ml-2">
											fastest
										</span>
									)}
								</span>
							</div>
							<div class="h-6 rounded-lg bg-black/5 dark:bg-white/5 overflow-hidden">
								<div
									class={`h-full rounded-lg transition-[width] duration-700 ease-out flex items-center justify-end pr-2 ${isLde ? "bg-blue-500" : "bg-gray-300 dark:bg-gray-600"}`}
									style={{ width: animated ? `${(r.time / max) * 100}%` : "0%" }}
								>
									{rank > 0 && animated && (
										<span class="text-xs font-medium text-white/70 whitespace-nowrap">
											{(r.time / sorted[0].time).toFixed(1)}x slower
										</span>
									)}
								</div>
							</div>
						</div>
					);
				})}
			</div>
			{/* Footer */}
			<div class="px-6 py-3 border-t border-gray-200 dark:border-gray-700 flex items-center justify-between">
				<span class="text-xs text-gray-400 dark:text-gray-500">Linux x86-64 · 16 cores · avg of 4 runs · 3/31/26, latest versions</span>
				<a href="https://github.com/lde-org/lde/tree/master/benchmarks" class="text-xs text-gray-400 dark:text-gray-500 hover:text-gray-600 dark:hover:text-gray-300 transition-colors">View source</a>
			</div>
		</div>
	);
}
