import { useState, useEffect, useRef } from "preact/hooks";

type Line =
	| { type: "cmd"; text: string }
	| { type: "out"; text: string }
	| { type: "replace"; text: string } // replaces the previous line after a delay
	| { type: "blank" };

const tabs: { id: string; label: string; lines: Line[] }[] = [
	{
		id: "new",
		label: "lde new",
		lines: [
			{ type: "cmd", text: "lde new myproject && cd myproject" },
			{ type: "out", text: "✓ Created myproject/" },
			{ type: "blank" },
			{ type: "cmd", text: "lde tree" },
			{ type: "out", text: "myproject" },
			{ type: "out", text: "└── (no dependencies)" },
			{ type: "blank" },
			{ type: "cmd", text: "lde add hood --git https://github.com/codebycruz/hood" },
			{ type: "out", text: "✓ Installed hood" },
			{ type: "blank" },
			{ type: "cmd", text: "lde tree" },
			{ type: "out", text: "myproject" },
			{ type: "out", text: "└── hood (git)" },
		],
	},
	{
		id: "ldx",
		label: "ldx cowsay",
		lines: [
			{ type: "cmd", text: "ldx cowsay Hi there" },
			{ type: "out", text: "  - Cloning cowsay (git@github.com:codebycruz/cowsay.git)" },
			{ type: "replace", text: "  ✓ Cloned cowsay" },
			{ type: "out", text: " ----------" },
			{ type: "out", text: "< Hi there >" },
			{ type: "out", text: " ----------" },
			{ type: "out", text: "        \\   ^__^" },
			{ type: "out", text: "         \\  (oo)\\_______" },
			{ type: "out", text: "            (__)\\       )\\/\\" },
			{ type: "out", text: "                ||----w |" },
			{ type: "out", text: "                ||     ||" },
		],
	},
	{
		id: "compile",
		label: "lde compile",
		lines: [] as Line[], // populated dynamically
	},
	{
		id: "busted",
		label: "busted",
		lines: [
			{ type: "cmd", text: "lde install rocks:busted" },
			{ type: "out", text: "✓ Installed busted" },
			{ type: "blank" },
			{ type: "cmd", text: "busted" },
			{ type: "out", text: "●●●●●" },
			{ type: "blank" },
			{ type: "out", text: "5 successes / 0 failures / 0 errors" },
			{ type: "out", text: "0.003 seconds" },
		],
	},
];

const pkgNames = ["winapi", "luasocket", "json", "lpeg", "luafilesystem", "luaposix"];

export default function TerminalDemo() {
	const [activeId, setActiveId] = useState(tabs[0].id);
	const [visibleCount, setVisibleCount] = useState(0);
	const [pkg, setPkg] = useState(pkgNames[0]);
	const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

	const activeTab = tabs.find((t) => t.id === activeId)!;
	const compileLines: Line[] = [
		{ type: "cmd", text: "lde compile" },
		{ type: "out", text: `  - Cloning ${pkg}` },
		{ type: "replace", text: `  ✓ Cloned ${pkg}` },
		{ type: "out", text: `  - Building ${pkg}` },
		{ type: "replace", text: `  ✓ Built ${pkg}` },
		{ type: "out", text: "Executable created: ./dist/myproject" },
	];
	const lines = activeId === "compile" ? compileLines : activeTab.lines;

	useEffect(() => {
		setPkg(pkgNames[Math.floor(Math.random() * pkgNames.length)]);
		setVisibleCount(0);
		let i = 0;
		function next() {
			i++;
			setVisibleCount(i);
			if (i < lines.length) {
				const line = lines[i - 1];
				const next_line = activeId === "compile" ? compileLines[i] : activeTab.lines[i];
				const delay = line.type === "cmd" ? 400 : next_line?.type === "replace" ? 2000 : 80;
				timerRef.current = setTimeout(next, delay);
			}
		}
		timerRef.current = setTimeout(next, 200);
		return () => {
			if (timerRef.current) clearTimeout(timerRef.current);
		};
	}, [activeId, pkg]);

	// Build rendered lines, applying replacements
	const rendered: { text: string; type: "cmd" | "out" | "blank" }[] = [];
	for (const line of lines.slice(0, visibleCount)) {
		if (line.type === "replace") {
			rendered[rendered.length - 1] = { type: "out", text: line.text };
		} else if (line.type === "blank") {
			rendered.push({ type: "blank", text: "" });
		} else {
			rendered.push({ type: line.type, text: line.text });
		}
	}

	return (
		<div class="w-[560px] rounded-xl border border-white/10 bg-[#0a0a0f] overflow-hidden shadow-2xl font-mono text-sm">
			{/* Title bar */}
			<div class="flex items-center gap-1.5 px-4 py-3 border-b border-white/10 bg-[#111118]">
				<span class="size-3 rounded-full bg-red-500/70" />
				<span class="size-3 rounded-full bg-yellow-500/70" />
				<span class="size-3 rounded-full bg-green-500/70" />
				<span class="ml-3 text-white/30 text-xs">lde — terminal</span>
			</div>

			{/* Tabs */}
			<div class="flex border-b border-white/10">
				{tabs.map((tab) => (
					<button
						key={tab.id}
						type="button"
						onClick={() => setActiveId(tab.id)}
						class={`px-4 py-2 text-xs cursor-pointer transition-colors border-b-2 -mb-px ${
							activeId === tab.id
								? "border-blue-500 text-white"
								: "border-transparent text-white/40 hover:text-white/70"
						}`}
					>
						{tab.label}
					</button>
				))}
			</div>

			{/* Terminal body */}
			<div class="p-4 h-[280px] space-y-0.5">
				{rendered.map((line, i) => {
					if (line.type === "blank") return <div key={i} class="h-2" />;
					if (line.type === "cmd")
						return (
							<div key={i} class="flex gap-2">
								<span class="text-blue-400 select-none">$</span>
								<span class="text-white/90">{line.text}</span>
							</div>
						);
					return (
						<div key={i} class="text-white/50 pl-4 whitespace-pre">
							{line.text}
						</div>
					);
				})}
				{visibleCount < lines.length && (
					<span class="inline-block w-2 h-4 bg-white/70 animate-pulse ml-4" />
				)}
			</div>
		</div>
	);
}
