import { useState, useEffect } from "preact/hooks";
import { GITHUB_RELEASES_URL } from "../data/info";
import { CopyButton } from "./CopyButton";

function detectOS(): string {
	const p = navigator.platform.toLowerCase();
	if (p.includes("win")) return "windows";
	return "linux";
}

const tabs = [
	{
		id: "linux",
		label: "Linux & macOS",
		command: "curl -fsSL https://lualpm.com/install | sh",
	},
	{
		id: "windows",
		label: "Windows",
		command: "irm https://lualpm.com/install.ps1 | iex",
	},
] as const;

const maxCommand = tabs.reduce(
	(max, t) => (t.command.length > max.length ? t.command : max),
	"",
);

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
								class={`px-4 py-2 cursor-pointer transition-colors text-sm border-b-2 -mb-px ${
									isActive
										? "border-blue-500 text-gray-800 dark:text-gray-200"
										: "border-transparent text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200"
								}`}
							>
								{tab.label}
							</button>
						);
					})}
					<a
						href={GITHUB_RELEASES_URL}
						target="_blank"
						rel="noopener noreferrer"
						class="ml-auto px-4 py-2 text-sm opacity-40 hover:opacity-100 transition-opacity cursor-pointer flex items-center"
					>
						Or download manually
					</a>
				</div>
				<div class="flex items-center px-4 py-3 bg-gray-50 dark:bg-gray-900 overflow-x-auto">
					<span class="text-blue-500 dark:text-blue-400 mr-3 select-none font-mono text-sm shrink-0">
						$
					</span>
					<div class="relative flex items-center min-w-0">
						<code class="text-sm text-gray-800 dark:text-gray-200 font-mono whitespace-nowrap invisible hidden lg:inline">
							{maxCommand}
						</code>
						<code class="text-sm text-gray-800 dark:text-gray-200 font-mono whitespace-nowrap lg:absolute lg:inset-0 lg:flex lg:items-center">
							{activeTab.command}
						</code>
					</div>
					<div class="ml-auto shrink-0">
						<CopyButton getText={() => activeTab.command} />
					</div>
				</div>
			</div>
		</div>
	);
}
