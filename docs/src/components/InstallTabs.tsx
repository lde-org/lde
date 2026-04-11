import { useState, useEffect } from "preact/hooks";
import { GITHUB_RELEASES_URL } from "../data/info";
import { CopyButton } from "./CopyButton";

function detectOS(): string {
	const ua = navigator.userAgent.toLowerCase();
	const p = navigator.platform.toLowerCase();
	if (ua.includes("android")) return "android";
	if (p.includes("win")) return "windows";
	return "linux";
}

const tabs = [
	{
		id: "linux",
		label: "Linux & macOS",
		labelShort: "Linux",
		command: "curl -fsSL https://lde.sh/install | sh",
		highlighted: <>curl -fsSL <span class="text-emerald-600 dark:text-emerald-300">https://lde.sh/install</span> <span class="text-black/30 dark:text-white/50">|</span> sh</>,
	},
	{
		id: "windows",
		label: "Windows",
		labelShort: "Windows",
		command: `powershell -c "irm https://lde.sh/install.ps1 | iex"`,
		highlighted: <>powershell <span class="text-sky-600 dark:text-sky-300">-c</span> <span class="text-emerald-600 dark:text-emerald-300">"irm https://lde.sh/install.ps1 | iex"</span></>,
	},
	{
		id: "android",
		label: "Android",
		labelShort: "Android",
		command: "curl -fsSL https://lde.sh/install | sh",
		highlighted: <>curl -fsSL <span class="text-emerald-600 dark:text-emerald-300">https://lde.sh/install</span> <span class="text-black/30 dark:text-white/50">|</span> sh</>,
	},
] as const;


export default function InstallTabs() {
	const [active, setActive] = useState<string>("linux");

	useEffect(() => {
		setActive(detectOS());
	}, []);

	const activeTab = tabs.find((t) => t.id === active) ?? tabs[0];

	return (
		<div class="flex flex-col gap-4">
			<h2 class="text-xl font-medium">Install latest version</h2>
			<div class="max-w-full border border-gray-200 dark:border-gray-700 rounded-lg overflow-hidden">
				<div class="flex items-center border-b border-gray-200 dark:border-gray-700">
					{tabs.map((tab) => {
						const isActive = active === tab.id;
						return (
							<button
								key={tab.id}
								type="button"
								onClick={() => setActive(tab.id)}
								class={`px-3 py-2 cursor-pointer transition-colors text-sm border-b-2 -mb-px ${
									isActive
										? "border-blue-500 text-gray-800 dark:text-gray-200"
										: "border-transparent text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200"
								}`}
							>
								<span class="sm:hidden">{tab.labelShort}</span>
								<span class="hidden sm:inline">{tab.label}</span>
							</button>
						);
					})}
					<a
						href={GITHUB_RELEASES_URL}
						target="_blank"
						rel="noopener noreferrer"
						class="ml-auto px-3 py-2 text-sm opacity-40 hover:opacity-100 transition-opacity cursor-pointer flex items-center gap-1.5 shrink-0"
						title="Download manually"
					>
						<span class="hidden sm:inline">Or download manually</span>
						<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/></svg>
					</a>
				</div>
				<div class="flex items-center px-4 py-3 bg-gray-50 dark:bg-gray-900 overflow-x-auto">
					<span class="text-blue-500 dark:text-blue-400 mr-3 select-none font-mono text-sm shrink-0">
						$
					</span>
					<code class="text-sm text-gray-800 dark:text-white font-mono whitespace-nowrap flex-1 text-left">
						{activeTab.highlighted}
					</code>
					<div class="ml-auto shrink-0 pl-3">
						<CopyButton getText={() => activeTab.command} />
					</div>
				</div>
			</div>
		</div>
	);
}
