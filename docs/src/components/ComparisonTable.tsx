import { useState } from "preact/hooks";

export type ComparisonRow = {
	feature: string;
	href: string;
	subtitle?: string;
	values: string[];
};

export default function ComparisonTable({ rows }: { rows: ComparisonRow[] }) {
	const [expanded, setExpanded] = useState(false);

	return (
		<div class="border border-black/10 dark:border-white/10 bg-black/[0.02] dark:bg-white/[0.02] overflow-hidden">
			{/* Collapsible body: height-limited until expanded */}
			<div
				id="comparison-collapse"
				inert={!expanded || undefined}
				class={`relative overflow-hidden transition-[max-height] duration-500 ease-in-out ${
					expanded ? "max-h-[2000px]" : "max-h-[320px] sm:max-h-[380px]"
				}`}
			>
				{/* Desktop table */}
				<div class="hidden sm:block overflow-x-auto">
					<div>
						<table class="w-full text-sm">
							<thead>
								<tr>
									<th scope="col" class="text-left px-6 py-4 font-medium text-black/35 dark:text-white/25 w-[40%]"></th>
									<th scope="col" class="text-center px-6 py-4 font-semibold text-blue-400">
										<span class="inline-flex items-center gap-2 text-[0.8125rem] font-brand">
											<img src="/lde-nospace.svg" class="h-5 opacity-90" alt="" />
											lde
										</span>
									</th>
									<th scope="col" class="text-center px-6 py-4 font-medium text-black/60 dark:text-white/50">luarocks</th>
									<th scope="col" class="text-center px-6 py-4 font-medium text-black/60 dark:text-white/50">lux</th>
								</tr>
							</thead>
							<tbody>
								{rows.map(({ feature, href, subtitle, values: cols }) => {
									const external = href.startsWith("http");
									return (
									<tr key={feature} class="border-t border-black/[0.05] dark:border-white/[0.06] transition-colors">
										<th scope="row" class="px-6 py-4 text-sm font-medium text-left">
											<a
												href={href}
												target={external ? "_blank" : undefined}
												rel={external ? "noopener noreferrer" : undefined}
												class="inline-flex items-center gap-1.5 text-black/70 dark:text-white/65 hover:text-blue-500 dark:hover:text-blue-400 transition-colors"
											>
												{feature}
												{external ? (
													<svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" class="opacity-45" aria-hidden="true">
														<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path>
														<polyline points="15 3 21 3 21 9"></polyline>
														<line x1="10" y1="14" x2="21" y2="3"></line>
													</svg>
												) : (
													<svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" class="opacity-45" aria-hidden="true">
														<path d="M7 17 17 7"></path>
														<path d="M7 7h10v10"></path>
													</svg>
												)}
											</a>
											{subtitle && <div class="mt-1 text-xs text-black/40 dark:text-white/30">{subtitle}</div>}
										</th>
										{cols.map((val, i) => {
											const blue = i === 0;
											const base = `px-6 py-4 align-middle text-center ${blue ? "text-blue-400 font-medium" : "text-black/70 dark:text-white/55"}`;
											if (val === "y") return <td key={i} class={base}><span class="inline-flex size-7 items-center justify-center rounded-full bg-emerald-500/14 text-emerald-700 dark:text-emerald-300 ring-1 ring-emerald-600/20 dark:ring-emerald-400/20"><svg xmlns="http://www.w3.org/2000/svg" class="size-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg></span></td>;
											if (val === "n") return <td key={i} class={base}><span class="inline-flex size-7 items-center justify-center rounded-full bg-red-500/12 text-red-700 dark:text-red-300 ring-1 ring-red-600/20 dark:ring-red-400/20"><svg xmlns="http://www.w3.org/2000/svg" class="size-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 6 6 18"/><path d="m6 6 12 12"/></svg></span></td>;
											if (val === "wip") return <td key={i} class={base}><span class="inline-flex size-7 items-center justify-center rounded-full bg-amber-500/18 text-amber-800 dark:text-amber-300 ring-1 ring-amber-600/20 dark:ring-amber-400/20"><svg xmlns="http://www.w3.org/2000/svg" class="size-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/><path d="M12 9v4"/><path d="M12 17h.01"/></svg></span></td>;
											if (val.startsWith("y:")) return (
												<td key={i} class={base}>
													<span title={val.slice(2)} class="inline-flex size-7 items-center justify-center rounded-full bg-emerald-500/14 text-emerald-700 dark:text-emerald-300 ring-1 ring-emerald-600/20 dark:ring-emerald-400/20">
														<svg xmlns="http://www.w3.org/2000/svg" class="size-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg>
													</span>
												</td>
											);
											if (val.startsWith("a:")) return (
												<td key={i} class={base}>
													<a href={href} class="inline-flex items-center gap-1.5 text-blue-500 dark:text-blue-400 hover:underline transition-colors">
														{val.slice(2)}
														<svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" class="opacity-45" aria-hidden="true">
															<path d="M7 17 17 7"></path>
															<path d="M7 7h10v10"></path>
														</svg>
													</a>
												</td>
											);
											return <td key={i} class={base}><span class={blue ? "text-blue-300" : ""}>{val}</span></td>;
										})}
									</tr>
									);
								})}
							</tbody>
						</table>
					</div>
				</div>

				{/* Mobile rows */}
				<div class="sm:hidden divide-y divide-black/[0.06] dark:divide-white/[0.06]">
					{rows.map(({ feature, href, subtitle, values }) => {
						const [lde, luarocks, lux] = values;
						const external = href.startsWith("http");
						const renderVal = (val: string, blue = false) => {
							const cls = blue ? "text-blue-500 dark:text-blue-400 font-semibold" : "text-black/65 dark:text-white/55";
							if (val === "y") return <span class="text-emerald-700 dark:text-emerald-300 font-bold">Yes</span>;
							if (val === "n") return <span class="text-red-700 dark:text-red-300 font-bold">No</span>;
							if (val === "wip") return <svg xmlns="http://www.w3.org/2000/svg" class="size-4 text-amber-800 dark:text-amber-300" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/><path d="M12 9v4"/><path d="M12 17h.01"/></svg>;
							if (val.startsWith("y:")) return <span title={val.slice(2)} class="text-emerald-700 dark:text-emerald-300 font-bold">Yes</span>;
							if (val.startsWith("a:")) return <a href={href} class="text-blue-500 dark:text-blue-400 font-semibold underline">{val.slice(2)}</a>;
							return <span class={cls}>{val}</span>;
						};
						return (
							<div key={feature} class="py-4">
								<p class="mb-3">
									<a
										href={href}
										target={external ? "_blank" : undefined}
										rel={external ? "noopener noreferrer" : undefined}
										class="inline-flex items-center gap-1.5 text-sm font-medium text-black/75 dark:text-white/65 hover:text-blue-500 dark:hover:text-blue-400 transition-colors"
									>
										{feature}
										{external ? (
											<svg xmlns="http://www.w3.org/2000/svg" width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" class="opacity-45" aria-hidden="true">
												<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path>
												<polyline points="15 3 21 3 21 9"></polyline>
												<line x1="10" y1="14" x2="21" y2="3"></line>
											</svg>
										) : (
											<svg xmlns="http://www.w3.org/2000/svg" width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" class="opacity-45" aria-hidden="true">
												<path d="M7 17 17 7"></path>
												<path d="M7 7h10v10"></path>
											</svg>
										)}
									</a>
								</p>
								{subtitle && <p class="mb-3 text-xs text-black/40 dark:text-white/30">{subtitle}</p>}
								<div class="grid grid-cols-3 gap-3 text-sm">
									<div class="flex flex-col gap-1 items-center text-center">
										<span class="text-[10px] text-blue-500 dark:text-blue-400 font-semibold font-brand">lde</span>
										{renderVal(lde, true)}
									</div>
									<div class="flex flex-col gap-1 items-center text-center">
										<span class="text-[10px] text-black/35 dark:text-white/25">luarocks</span>
										{renderVal(luarocks)}
									</div>
									<div class="flex flex-col gap-1 items-center text-center">
										<span class="text-[10px] text-black/35 dark:text-white/25">lux</span>
										{renderVal(lux)}
									</div>
								</div>
							</div>
						);
					})}
				</div>

				{/* Bottom fade when collapsed */}
				{!expanded && (
					<div
						class="pointer-events-none absolute inset-x-0 bottom-0 h-28 bg-gradient-to-t from-white dark:from-gray-950 to-transparent"
						aria-hidden="true"
					/>
				)}
			</div>

			{/* Expand / collapse toggle */}
			<button
				type="button"
				onClick={() => setExpanded((e) => !e)}
				aria-expanded={expanded}
				aria-controls="comparison-collapse"
				class="w-full flex items-center justify-center gap-2 px-4 py-3.5 text-sm font-medium text-black/60 dark:text-white/50 hover:text-black/90 dark:hover:text-white/90 hover:bg-black/[0.03] dark:hover:bg-white/[0.03] transition-colors cursor-pointer border-t border-black/[0.06] dark:border-white/[0.08]"
			>
				<span>{expanded ? "Show less" : `Show all ${rows.length} features`}</span>
				<svg
					xmlns="http://www.w3.org/2000/svg"
					class={`size-4 transition-transform duration-300 ${expanded ? "rotate-180" : ""}`}
					viewBox="0 0 24 24"
					fill="none"
					stroke="currentColor"
					stroke-width="2.25"
					stroke-linecap="round"
					stroke-linejoin="round"
					aria-hidden="true"
				>
					<path d="m6 9 6 6 6-6" />
				</svg>
			</button>
		</div>
	);
}
