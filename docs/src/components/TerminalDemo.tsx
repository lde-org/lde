import { useState, useEffect, useRef } from "preact/hooks";

type Line =
	| { type: "cmd"; text: string }
	| { type: "out"; text: string }
	| { type: "blank" };

const E = "\x1b[";

// Exact ANSI-colored output captured from running lde 0.11.0-nightly+3696fae
const tabs: { id: string; label: string; lines: Line[] }[] = [
	{
		id: "help",
		label: "lde help",
		lines: [
			{ type: "cmd", text: "lde help" },
			{ type: "out", text: `${E}34m${E}1mlde${E}0m is a package manager for Lua, written in Lua. ${E}90m(0.11.0-nightly+3696fae)` },
			{ type: "blank" },
			{ type: "out", text: `${E}1mUsage:${E}0m lde <command> ${E}35m[options]${E}0m` },
			{ type: "blank" },
			{ type: "out", text: `${E}1mCommands:${E}0m${E}0m` },
			{ type: "out", text: `  ${E}1m${E}32mhelp      ${E}0m  ${E}90m            ${E}0m Show help for a command${E}0m` },
			{ type: "out", text: `  ${E}1m${E}32mrun       ${E}0m  ${E}90m            ${E}0m Execute a project${E}0m` },
			{ type: "out", text: `  ${E}1m${E}32mx         ${E}0m  ${E}90m--git <url> ${E}0m Run a package from a git repo or path${E}0m` },
			{ type: "out", text: `  ${E}1m${E}32mrepl      ${E}0m  ${E}90m            ${E}0m Start an interactive LuaJIT REPL${E}0m` },
			{ type: "out", text: `  ${E}1m${E}32mtest      ${E}0m  ${E}90m            ${E}0m Run project tests${E}0m` },
			{ type: "blank" },
			{ type: "out", text: `  ${E}1m${E}31mnew       ${E}0m  ${E}90mmyproject   ${E}0m Create a new project${E}0m` },
			{ type: "out", text: `  ${E}1m${E}31minit      ${E}0m  ${E}90m            ${E}0m Initialize current directory as a project${E}0m` },
			{ type: "out", text: `  ${E}1m${E}31mupgrade   ${E}0m  ${E}90m            ${E}0m Upgrade lde to the latest version${E}0m` },
			{ type: "blank" },
			{ type: "out", text: `  ${E}1m${E}33msync      ${E}0m  ${E}90m            ${E}0m Install dependencies (--locked: from lockfile only)${E}0m` },
			{ type: "out", text: `  ${E}1m${E}33minstall   ${E}0m  ${E}90mrocks:tl    ${E}0m Install a tool to PATH with --git/--path/rocks:${E}0m` },
			{ type: "out", text: `  ${E}1m${E}33muninstall ${E}0m  ${E}90mtl          ${E}0m Uninstall a tool from PATH${E}0m` },
			{ type: "out", text: `  ${E}1m${E}33madd       ${E}0m  ${E}90mhood        ${E}0m Add a dependency (--path <path> or --git <url>)${E}0m` },
			{ type: "out", text: `  ${E}1m${E}33mremove    ${E}0m  ${E}90mjson        ${E}0m Remove a dependency${E}0m` },
			{ type: "out", text: `  ${E}1m${E}33mtree      ${E}0m  ${E}90m            ${E}0m Show the dependency tree${E}0m` },
			{ type: "out", text: `  ${E}1m${E}33mupdate    ${E}0m  ${E}90mclap        ${E}0m Update dependencies to their latest versions${E}0m` },
			{ type: "out", text: `  ${E}1m${E}33moutdated  ${E}0m  ${E}90m            ${E}0m Show dependencies with newer versions available${E}0m` },
			{ type: "out", text: `  ${E}1m${E}33mpublish   ${E}0m  ${E}90m            ${E}0m Create a PR to add your package to the registry${E}0m` },
			{ type: "out", text: `  ${E}1m${E}33msearch    ${E}0m  ${E}90mjson        ${E}0m Search the lde registry and luarocks${E}0m` },
			{ type: "blank" },
			{ type: "out", text: `  ${E}1m${E}35mcompile   ${E}0m  ${E}90m            ${E}0m Compile current project into an executable${E}0m` },
			{ type: "out", text: `  ${E}1m${E}35mbundle    ${E}0m  ${E}90m            ${E}0m Bundle current project into a single lua file${E}0m` },
			{ type: "out", text: `  ${E}1m${E}35mbloat     ${E}0m  ${E}90m            ${E}0m Show what makes up the compiled binary${E}0m` },
			{ type: "blank" },
			{ type: "out", text: `  ${E}1m${E}36mcompletion${E}0m  ${E}90mbash        ${E}0m Print a shell completion script (bash|zsh|fish)${E}0m` },
			{ type: "out", text: `  ${E}1m${E}90m<command> ${E}0m  ${E}36m--help      ${E}0m Print help text for command.${E}0m` },
			{ type: "blank" },
			{ type: "out", text: `${E}1mLearn more:             ${E}0m ${E}34m  https://lde.sh${E}0m` },
			{ type: "out", text: `${E}1mJoin the discord:       ${E}0m ${E}34m  https://lde.sh/discord${E}0m` },
		],
	},
	{
		id: "new",
		label: "lde new",
		lines: [], // generated dynamically — see buildNewLines()
	},
	{
		id: "ldx",
		label: "ldx cowsay",
		lines: [
			{ type: "cmd", text: "ldx cowsay Hi there" },
			{ type: "out", text: "----------" },
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
		lines: [
			{ type: "cmd", text: "lde compile" },
			{ type: "out", text: `${E}32m✓ ${E}0mDownloaded luajit for linux-x86-64 ${E}90m(0.72s)${E}0m` },
			{ type: "out", text: `${E}32mExecutable created: ./myproject${E}0m` },
		],
	},
	{
		id: "busted",
		label: "busted",
		lines: [
			{ type: "cmd", text: "lde install rocks:busted" },
			{ type: "out", text: `${E}32m✓ ${E}0m9 packages installed ${E}90m(1.14s)${E}0m` },
			{ type: "out", text: `${E}32mInstalled tool 'busted' -> ~/.lde/tools/busted${E}0m` },
			{ type: "blank" },
			{ type: "cmd", text: "busted" },
			{ type: "out", text: `${E}32m●${E}0m${E}32m●${E}0m${E}32m●${E}0m${E}32m●${E}0m${E}32m●${E}0m` },
			{ type: "out", text: `${E}32m5${E}0m successes / ${E}31m0${E}0m failures / ${E}35m0${E}0m errors / ${E}33m0${E}0m pending : ${E}1m0.000713${E}0m seconds` },
		],
	},
];

// Standard terminal palette for ANSI 30-37 / 90-97
const ANSI: Record<number, string> = {
	30: "#1a1a1a", 31: "#cd3131", 32: "#0dbc79", 33: "#e5e510", 34: "#2472c8",
	35: "#bc3fbc", 36: "#11a8cd", 37: "#e5e5e5",
	90: "#666666", 91: "#f14c4c", 92: "#23d18b", 93: "#f5f543", 94: "#3b8eea",
	95: "#d670d6", 96: "#29b8db", 97: "#e5e5e5",
};

// Interactive `lde new` choices (captured from the live prompt)
const PROJECT_TYPES = [
	{ id: "blank", color: 32, desc: "A basic hello world app" },
	{ id: "library", color: 33, desc: "A module other projects can require()" },
];

const LANGUAGES = [
	{ id: "lua", color: 34, desc: "Your typical lua project" },
	{ id: "moonscript", color: 35, desc: "A dynamically typed whitespace based language" },
	{ id: "teal", color: 36, desc: "Typed lua with type checking support" },
];

function randomNewChoice() {
	return {
		type: PROJECT_TYPES[Math.floor(Math.random() * PROJECT_TYPES.length)],
		lang: LANGUAGES[Math.floor(Math.random() * LANGUAGES.length)],
	};
}

// Reconstruct the interactive `lde new` session for the given choices as a
// sequence of screen states, each held for `delay` ms. The `>` selector
// advances one step per "arrow key press", matching the live prompt.
function buildNewSteps(
	type: (typeof PROJECT_TYPES)[number],
	lang: (typeof LANGUAGES)[number],
): { lines: Line[]; delay: number }[] {
	const typeIdx = PROJECT_TYPES.findIndex((t) => t.id === type.id);
	const langIdx = LANGUAGES.findIndex((l) => l.id === lang.id);
	const option = (name: string, color: number, desc: string, selected: boolean) =>
		selected
			? `${E}32m> ${E}0m${E}4m${E}1m${E}${color}m${name}${E}0m  ${E}90m${desc}${E}0m`
			: `  ${E}1m${E}${color}m${name}${E}0m  ${E}90m${desc}${E}0m`;
	const optLine = (name: string, color: number, desc: string, selected: boolean): Line => ({
		type: "out",
		text: option(name, color, desc, selected),
	});
	const settled = (label: string, answer: string, color: number) =>
		`${E}36m?${E}0m ${E}1m${label}${E}0m: ${E}0m${E}${color}m${answer}${E}0m`;

	const cmd: Line = { type: "cmd", text: "lde new myproject" };
	const typeHeader: Line = { type: "out", text: `${E}36m?${E}0m ${E}1mProject type${E}0m` };
	const langHeader: Line = { type: "out", text: `${E}36m?${E}0m ${E}1mLanguage${E}0m` };
	const typeSettled: Line = { type: "out", text: settled("Project type", type.id, type.color) };
	const langSettled: Line = { type: "out", text: settled("Language", lang.id, lang.color) };
	const pkgPrompt: Line = {
		type: "out",
		text: `${E}36m?${E}0m ${E}1mPackage name${E}0m (myproject): ${E}0mmyproject`,
	};
	const created: Line = { type: "out", text: `${E}32mCreated directory: myproject${E}0m` };

	const steps: { lines: Line[]; delay: number }[] = [{ lines: [cmd], delay: 700 }];

	// Project type: list appears, then ↓ presses, then it settles
	steps.push({
		lines: [cmd, typeHeader, ...PROJECT_TYPES.map((t, i) => optLine(t.id, t.color, t.desc, i === 0))],
		delay: 1100,
	});
	for (let i = 1; i <= typeIdx; i++) {
		steps.push({
			lines: [cmd, typeHeader, ...PROJECT_TYPES.map((t, j) => optLine(t.id, t.color, t.desc, j === i))],
			delay: 700,
		});
	}
	steps.push({ lines: [cmd, typeSettled], delay: 900 });

	// Language: list appears, then ↓ presses, then it settles
	steps.push({
		lines: [cmd, typeSettled, langHeader, ...LANGUAGES.map((l, i) => optLine(l.id, l.color, l.desc, i === 0))],
		delay: 1100,
	});
	for (let i = 1; i <= langIdx; i++) {
		steps.push({
			lines: [cmd, typeSettled, langHeader, ...LANGUAGES.map((l, j) => optLine(l.id, l.color, l.desc, j === i))],
			delay: 700,
		});
	}
	steps.push({ lines: [cmd, typeSettled, langSettled], delay: 900 });

	// Package name is "typed", then the project is created
	steps.push({ lines: [cmd, typeSettled, langSettled, pkgPrompt], delay: 1200 });
	steps.push({ lines: [cmd, typeSettled, langSettled, pkgPrompt, created], delay: 800 });

	return steps;
}

function renderAnsi(text: string, key: number): preact.JSX.Element[] {
	const parts: preact.JSX.Element[] = [];
	let fg: string | null = null;
	let bold = false;
	let last = 0;
	const re = /\x1b\[([0-9;]*)m/g;
	let m: RegExpExecArray | null;
	while ((m = re.exec(text))) {
		if (m.index > last) {
			parts.push(
				<span
					key={parts.length}
					style={{ color: fg ?? undefined, fontWeight: bold ? 600 : undefined }}
				>
					{text.slice(last, m.index)}
				</span>,
			);
		}
		for (const code of m[1].split(";")) {
			const c = parseInt(code, 10);
			if (c === 0) {
				fg = null;
				bold = false;
			} else if (c === 1) {
				bold = true;
			} else if (c >= 30 && c <= 37) {
				fg = ANSI[c];
			} else if (c >= 90 && c <= 97) {
				fg = ANSI[c];
			}
		}
		last = m.index + m[0].length;
	}
	if (last < text.length) {
		parts.push(
			<span
				key={parts.length}
				style={{ color: fg ?? undefined, fontWeight: bold ? 600 : undefined }}
			>
				{text.slice(last)}
			</span>,
		);
	}
	return parts;
}

export default function TerminalDemo() {
	const [activeId, setActiveId] = useState(tabs[0].id);
	const [visibleCount, setVisibleCount] = useState(0);
	const [stepIdx, setStepIdx] = useState(0);
	const [userInteracted, setUserInteracted] = useState(false);
	const [newChoice, setNewChoice] = useState(randomNewChoice);
	const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
	const bodyRef = useRef<HTMLDivElement>(null);

	const activeTab = tabs.find((t) => t.id === activeId)!;
	const interactiveSteps =
		activeId === "new" ? buildNewSteps(newChoice.type, newChoice.lang) : null;
	const lines = activeTab.lines;
	const playing = interactiveSteps
		? stepIdx < interactiveSteps.length - 1
		: visibleCount < lines.length;
	const rendered = interactiveSteps
		? interactiveSteps[Math.min(stepIdx, interactiveSteps.length - 1)]?.lines ?? []
		: lines.slice(0, visibleCount);

	function goToTab(id: string) {
		setActiveId(id);
		setStepIdx(0);
		setVisibleCount(0);
		if (id === "new") setNewChoice(randomNewChoice());
	}

	useEffect(() => {
		setVisibleCount(0);
		setStepIdx(0);

		if (interactiveSteps) {
			// Interactive sequence: advance through screen states on a timer,
			// pausing between "arrow key presses" and choices.
			let i = 0;
			function nextStep() {
				i++;
				setStepIdx(i);
				if (i < interactiveSteps.length) {
					timerRef.current = setTimeout(nextStep, interactiveSteps[i].delay);
				}
			}
			timerRef.current = setTimeout(nextStep, interactiveSteps[0].delay);
			return () => {
				if (timerRef.current) clearTimeout(timerRef.current);
			};
		}

		// Typewriter: reveal lines one by one
		let i = 0;
		function next() {
			i++;
			setVisibleCount(i);
			if (i < lines.length) {
				const line = lines[i - 1];
				const delay = line.type === "cmd" ? 400 : 80;
				timerRef.current = setTimeout(next, delay);
			}
		}
		timerRef.current = setTimeout(next, 50);
		return () => {
			if (timerRef.current) clearTimeout(timerRef.current);
		};
	}, [activeId, newChoice]);

	// Auto-cycle: once a tab has finished playing (and the user hasn't
	// interacted), hold for 5s then move on to the next example.
	useEffect(() => {
		if (userInteracted || playing) return;
		const t = setTimeout(() => {
			setActiveId((id) => {
				const idx = tabs.findIndex((x) => x.id === id);
				const next = tabs[(idx + 1) % tabs.length].id;
				if (next === "new") setNewChoice(randomNewChoice());
				return next;
			});
		}, 5000);
		return () => clearTimeout(t);
	}, [userInteracted, playing, activeId]);

	// Keep the latest output in view while typing (the help example is long)
	useEffect(() => {
		const el = bodyRef.current;
		if (el) el.scrollTop = el.scrollHeight;
	}, [visibleCount, activeId, stepIdx]);

	function switchTab(id: string) {
		if (id === activeId) return;
		setUserInteracted(true);
		setVisibleCount(0);
		goToTab(id);
	}

	return (
		<div class="w-[640px] border border-black/10 dark:border-white/10 bg-gray-100 dark:bg-[#0a0a0f] overflow-hidden font-mono text-sm">
			{/* Tabs */}
			<div class="flex border-b border-black/10 dark:border-white/10 bg-gray-200 dark:bg-[#111118]">
				{tabs.map((tab) => (
					<button
						key={tab.id}
						type="button"
						onClick={() => switchTab(tab.id)}
						class={`px-3 py-2 text-xs cursor-pointer transition-colors border-b-2 -mb-px whitespace-nowrap ${
							activeId === tab.id
								? "border-blue-600 text-black dark:text-white"
								: "border-transparent text-black/40 dark:text-white/40 hover:text-black/70 dark:hover:text-white/70"
						}`}
					>
						{tab.label}
					</button>
				))}
			</div>

			{/* Terminal body */}
			<div ref={bodyRef} class="p-4 h-[400px] overflow-y-auto space-y-0.5">
				{rendered.map((line, i) => {
					if (line.type === "blank") return <div key={i} class="h-2" />;
					if (line.type === "cmd")
						return (
							<div key={i} class="flex gap-2">
								<span class="text-blue-500 dark:text-blue-400 select-none">$</span>
								<span class="text-black/90 dark:text-white/90 whitespace-pre">{line.text}</span>
							</div>
						);
					return (
						<div key={i} class="text-black/85 dark:text-white/85 whitespace-pre">
							{renderAnsi(line.text, i)}
						</div>
					);
				})}
				{playing && (
					<span class="inline-block w-2 h-4 bg-black/70 dark:bg-white/70 animate-pulse ml-4" />
				)}
			</div>
		</div>
	);
}
