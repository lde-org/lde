import { useState, useEffect } from "preact/hooks";
import { GITHUB_RELEASES_URL } from "../data/info";

const TerminalIcon = () => (
	<svg
		xmlns="http://www.w3.org/2000/svg"
		viewBox="0 0 24 24"
		fill="none"
		stroke="currentColor"
		stroke-width="2"
		stroke-linecap="round"
		stroke-linejoin="round"
		class="size-4"
	>
		<polyline points="4 17 10 11 4 5" />
		<line x1="12" x2="20" y1="19" y2="19" />
	</svg>
);
const PackageIcon = () => (
	<svg
		xmlns="http://www.w3.org/2000/svg"
		viewBox="0 0 24 24"
		fill="none"
		stroke="currentColor"
		stroke-width="2"
		stroke-linecap="round"
		stroke-linejoin="round"
		class="size-4"
	>
		<path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z" />
	</svg>
);
const CopyIcon = () => (
	<svg
		xmlns="http://www.w3.org/2000/svg"
		width="15"
		height="15"
		viewBox="0 0 24 24"
		fill="none"
		stroke="currentColor"
		stroke-width="2"
		stroke-linecap="round"
		stroke-linejoin="round"
	>
		<rect width="14" height="14" x="8" y="8" rx="2" ry="2" />
		<path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2" />
	</svg>
);
const CheckIcon = () => (
	<svg
		xmlns="http://www.w3.org/2000/svg"
		width="15"
		height="15"
		viewBox="0 0 24 24"
		fill="none"
		stroke="currentColor"
		stroke-width="2.5"
		stroke-linecap="round"
		stroke-linejoin="round"
	>
		<polyline points="20 6 9 17 4 12" />
	</svg>
);

type Platform = {
	id: string;
	label: string;
	icon: preact.JSX.Element;
	arches: string[];
};
type Method = {
	id: string;
	label: string;
	icon: preact.JSX.Element;
	command: string;
	note?: preact.JSX.Element;
};

const platforms: Platform[] = [
	{
		id: "macos",
		label: "macOS",
		arches: ["arm64", "x86-64"],
		icon: (
			<svg
				xmlns="http://www.w3.org/2000/svg"
				viewBox="0 0 24 24"
				fill="currentColor"
				class="size-6"
			>
				<path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z" />
			</svg>
		),
	},
	{
		id: "windows",
		label: "Windows",
		arches: ["x86-64", "arm64"],
		icon: (
			<svg
				xmlns="http://www.w3.org/2000/svg"
				viewBox="0 0 24 24"
				fill="currentColor"
				class="size-6"
			>
				<path d="M3 12V6.75l6-1.32v6.57H3zm17 0V3l-9 1.68V12h9zm-17 1h6v6.57l-6-1.32V13zm17 0h-9v7.32L20 22V13z" />
			</svg>
		),
	},
	{
		id: "linux",
		label: "Linux",
		arches: ["x86-64", "arm64"],
		icon: (
			<svg
				xmlns="http://www.w3.org/2000/svg"
				width="24"
				height="24"
				fill="currentColor"
				class="bi bi-tux"
				viewBox="0 0 16 16"
			>
				<path d="M8.996 4.497c.104-.076.1-.168.186-.158s.022.102-.098.207c-.12.104-.308.243-.46.323-.291.152-.631.336-.993.336s-.647-.167-.853-.33c-.102-.082-.186-.162-.248-.221-.11-.086-.096-.207-.052-.204.075.01.087.109.134.153.064.06.144.137.241.214.195.154.454.304.778.304s.702-.19.932-.32c.13-.073.297-.204.433-.304M7.34 3.781c.055-.02.123-.031.174-.003.011.006.024.021.02.034-.012.038-.074.032-.11.05-.032.017-.057.052-.093.054-.034 0-.086-.012-.09-.046-.007-.044.058-.072.1-.089m.581-.003c.05-.028.119-.018.173.003.041.017.106.045.1.09-.004.033-.057.046-.09.045-.036-.002-.062-.037-.093-.053-.036-.019-.098-.013-.11-.051-.004-.013.008-.028.02-.034" />
				<path
					fill-rule="evenodd"
					d="M8.446.019c2.521.003 2.38 2.66 2.364 4.093-.01.939.509 1.574 1.04 2.244.474.56 1.095 1.38 1.45 2.32.29.765.402 1.613.115 2.465a.8.8 0 0 1 .254.152l.001.002c.207.175.271.447.329.698.058.252.112.488.224.615.344.382.494.667.48.922-.015.254-.203.43-.435.57-.465.28-1.164.491-1.586 1.002-.443.527-.99.83-1.505.871a1.25 1.25 0 0 1-1.256-.716v-.001a1 1 0 0 1-.078-.21c-.67.038-1.252-.165-1.718-.128-.687.038-1.116.204-1.506.206-.151.331-.445.547-.808.63-.5.114-1.126 0-1.743-.324-.577-.306-1.31-.278-1.85-.39-.27-.057-.51-.157-.626-.384-.116-.226-.095-.538.07-.988.051-.16.012-.398-.026-.648a2.5 2.5 0 0 1-.037-.369c0-.133.022-.265.087-.386v-.002c.14-.266.368-.377.577-.451s.397-.125.53-.258c.143-.15.27-.374.443-.56q.036-.037.073-.07c-.081-.538.007-1.105.192-1.662.393-1.18 1.223-2.314 1.811-3.014.502-.713.65-1.287.701-2.016.042-.997-.705-3.974 2.112-4.2q.168-.015.321-.013m2.596 10.866-.03.016c-.223.121-.348.337-.427.656-.08.32-.107.733-.13 1.206v.001c-.023.37-.192.824-.31 1.267s-.176.862-.036 1.128v.002c.226.452.608.636 1.051.601s.947-.304 1.36-.795c.474-.576 1.218-.796 1.638-1.05.21-.126.324-.242.333-.4.009-.157-.097-.403-.425-.767-.17-.192-.217-.462-.274-.71-.056-.247-.122-.468-.26-.585l-.001-.001c-.18-.157-.356-.17-.565-.164q-.069.001-.14.005c-.239.275-.805.612-1.197.508-.359-.09-.562-.508-.587-.918m-7.204.03H3.83c-.189.002-.314.09-.44.225-.149.158-.276.382-.445.56v.002h-.002c-.183.184-.414.239-.61.31-.195.069-.353.143-.46.35v.002c-.085.155-.066.378-.029.624.038.245.096.507.018.746v.002l-.001.002c-.157.427-.155.678-.082.822.074.143.235.22.48.272.493.103 1.26.069 1.906.41.583.305 1.168.404 1.598.305.431-.098.712-.369.75-.867v-.002c.029-.292-.195-.673-.485-1.052-.29-.38-.633-.752-.795-1.09v-.002l-.61-1.11c-.21-.286-.43-.462-.68-.5a1 1 0 0 0-.106-.008M9.584 4.85c-.14.2-.386.37-.695.467-.147.048-.302.17-.495.28a1.3 1.3 0 0 1-.74.19.97.97 0 0 1-.582-.227c-.14-.113-.25-.237-.394-.322a3 3 0 0 1-.192-.126c-.063 1.179-.85 2.658-1.226 3.511a5.4 5.4 0 0 0-.43 1.917c-.68-.906-.184-2.066.081-2.568.297-.55.343-.701.27-.649-.266.436-.685 1.13-.848 1.844-.085.372-.1.749.01 1.097.11.349.345.67.766.931.573.351.963.703 1.193 1.015s.302.584.23.777a.4.4 0 0 1-.212.22.7.7 0 0 1-.307.056l.184.235c.094.124.186.249.266.375 1.179.805 2.567.496 3.568-.218.1-.342.197-.664.212-.903.024-.474.05-.896.136-1.245s.244-.634.53-.791a1 1 0 0 1 .138-.061q.005-.045.013-.087c.082-.546.569-.572 1.18-.303.588.266.81.499.71.814h.13c.122-.398-.133-.69-.822-1.025l-.137-.06a2.35 2.35 0 0 0-.012-1.113c-.188-.79-.704-1.49-1.098-1.838-.072-.003-.065.06.081.203.363.333 1.156 1.532.727 2.644a1.2 1.2 0 0 0-.342-.043c-.164-.907-.543-1.66-.735-2.014-.359-.668-.918-2.036-1.158-2.983M7.72 3.503a1 1 0 0 0-.312.053c-.268.093-.447.286-.559.391-.022.021-.05.04-.119.091s-.172.126-.321.238q-.198.151-.13.38c.046.15.192.325.459.476.166.098.28.23.41.334a1 1 0 0 0 .215.133.9.9 0 0 0 .298.066c.282.017.49-.068.673-.173s.34-.233.518-.29c.365-.115.627-.345.709-.564a.37.37 0 0 0-.01-.309c-.048-.096-.148-.187-.318-.257h-.001c-.354-.151-.507-.162-.705-.29-.321-.207-.587-.28-.807-.279m-.89-1.122h-.025a.4.4 0 0 0-.278.135.76.76 0 0 0-.191.334 1.2 1.2 0 0 0-.051.445v.001c.01.162.041.299.102.436.05.116.109.204.183.274l.089-.065.117-.09-.023-.018a.4.4 0 0 1-.11-.161.7.7 0 0 1-.054-.22v-.01a.7.7 0 0 1 .014-.234.4.4 0 0 1 .08-.179q.056-.069.126-.073h.013a.18.18 0 0 1 .123.05c.045.04.08.09.11.162a.7.7 0 0 1 .054.22v.01a.7.7 0 0 1-.002.17 1.1 1.1 0 0 1 .317-.143 1.3 1.3 0 0 0 .002-.194V3.23a1.2 1.2 0 0 0-.102-.437.8.8 0 0 0-.227-.31.4.4 0 0 0-.268-.102m1.95-.155a.63.63 0 0 0-.394.14.9.9 0 0 0-.287.376 1.2 1.2 0 0 0-.1.51v.015q0 .079.01.152c.114.027.278.074.406.138a1 1 0 0 1-.011-.172.8.8 0 0 1 .058-.278.5.5 0 0 1 .139-.2.26.26 0 0 1 .182-.069.26.26 0 0 1 .178.081c.055.054.094.12.124.21.029.086.042.17.04.27l-.002.012a.8.8 0 0 1-.057.277c-.024.059-.089.106-.122.145.046.016.09.03.146.052a5 5 0 0 1 .248.102 1.2 1.2 0 0 0 .244-.763 1.2 1.2 0 0 0-.11-.495.9.9 0 0 0-.294-.37.64.64 0 0 0-.39-.133z"
				/>
			</svg>
		),
	},
	{
		id: "android",
		label: "Android",
		arches: ["arm64"],
		icon: (
			<svg
				xmlns="http://www.w3.org/2000/svg"
				viewBox="0 0 24 24"
				fill="currentColor"
				class="size-6"
			>
				<path d="M6 18c0 .55.45 1 1 1h1v3.5c0 .83.67 1.5 1.5 1.5s1.5-.67 1.5-1.5V19h2v3.5c0 .83.67 1.5 1.5 1.5s1.5-.67 1.5-1.5V19h1c.55 0 1-.45 1-1V8H6v10zM3.5 8C2.67 8 2 8.67 2 9.5v7c0 .83.67 1.5 1.5 1.5S5 17.33 5 16.5v-7C5 8.67 4.33 8 3.5 8zm17 0c-.83 0-1.5.67-1.5 1.5v7c0 .83.67 1.5 1.5 1.5s1.5-.67 1.5-1.5v-7c0-.83-.67-1.5-1.5-1.5zm-4.97-5.84l1.3-1.3c.2-.2.2-.51 0-.71-.2-.2-.51-.2-.71 0l-1.48 1.48A5.84 5.84 0 0 0 12 1.5c-.96 0-1.86.23-2.66.63L7.88.65c-.2-.2-.51-.2-.71 0-.2.2-.2.51 0 .71l1.3 1.3A5.9 5.9 0 0 0 6.02 7h11.96c0-2.01-1-3.78-2.45-4.84zM10 5H9V4h1v1zm5 0h-1V4h1v1z" />
			</svg>
		),
	},
];

const methods: Record<string, Method[]> = {
	macos: [
		{
			id: "curl",
			label: "curl",
			icon: <TerminalIcon />,
			command: "curl -fsSL https://lde.sh/install | sh",
		},
		{
			id: "luarocks",
			label: "LuaRocks",
			icon: <PackageIcon />,
			command: "luarocks install lde",
		},
	],
	windows: [
		{
			id: "powershell",
			label: "PowerShell",
			icon: <TerminalIcon />,
			command: `powershell -c "irm https://lde.sh/install.ps1 | iex"`,
		},
		{
			id: "luarocks",
			label: "LuaRocks",
			icon: <PackageIcon />,
			command: "luarocks install lde",
		},
	],
	linux: [
		{
			id: "curl",
			label: "curl",
			icon: <TerminalIcon />,
			command: "curl -fsSL https://lde.sh/install | sh",
		},
		{
			id: "luarocks",
			label: "LuaRocks",
			icon: <PackageIcon />,
			command: "luarocks install lde",
		},
	],
	android: [
		{
			id: "curl",
			label: "curl (Termux)",
			icon: <TerminalIcon />,
			command: "curl -fsSL https://lde.sh/install | sh",
			note: (
				<>
					Requires{" "}
					<a
						href="https://termux.dev"
						target="_blank"
						rel="noopener noreferrer"
						class="text-blue-400 underline hover:text-blue-300"
					>
						Termux
					</a>
					.
				</>
			),
		},
	],
};

function detectPlatform() {
	const ua = navigator.userAgent.toLowerCase();
	if (ua.includes("android")) return "android";
	if (ua.includes("win")) return "windows";
	if (ua.includes("mac")) return "macos";
	return "linux";
}

function detectArch(platformId: string) {
	const ua = navigator.userAgent.toLowerCase();
	if (ua.includes("arm") || ua.includes("aarch")) return "arm64";
	if (platformId === "macos") return "arm64"; // default Apple Silicon
	return "x86-64";
}

function CopyButton({ text }: { text: string }) {
	const [copied, setCopied] = useState(false);
	return (
		<button
			type="button"
			class="cursor-pointer shrink-0 ml-2 text-black/30 dark:text-white/30 hover:text-black/70 dark:hover:text-white/70 transition-colors"
			onClick={async () => {
				await navigator.clipboard.writeText(text);
				setCopied(true);
				setTimeout(() => setCopied(false), 1500);
			}}
			aria-label="Copy"
		>
			{copied ? <CheckIcon /> : <CopyIcon />}
		</button>
	);
}

export default function DownloadPanel() {
	const [platform, setPlatform] = useState("linux");
	const [arch, setArch] = useState("x86-64");
	const [nightly, setNightly] = useState(false);

	useEffect(() => {
		const p = detectPlatform();
		setPlatform(p);
		setArch(detectArch(p));
	}, []);

	const p = platforms.find((p) => p.id === platform)!;
	const ms = methods[platform] ?? [];

	function applyNightly(cmd: string) {
		if (!nightly) return cmd;
		if (cmd === "luarocks install lde") return cmd;
		if (cmd.includes("| sh"))
			return cmd.replace("| sh", "| sh -s -- --nightly");
		if (cmd.includes("| iex"))
			return `iex "& {$(irm https://lde.sh/install.ps1)} --nightly"`;
		return cmd;
	}

	return (
		<div class="w-full lg:w-3xl">
			{/* Platform picker */}
			<div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-8">
				{platforms.map((pl) => (
					<button
						key={pl.id}
						type="button"
						onClick={() => {
							setPlatform(pl.id);
							setArch(detectArch(pl.id));
						}}
						class={`cursor-pointer flex flex-col items-center gap-2 p-4 rounded-xl border transition-all text-sm font-medium ${
							platform === pl.id
								? "border-blue-500/50 bg-blue-500/[0.06] text-blue-400"
								: "border-black/10 dark:border-white/10 bg-black/[0.02] dark:bg-white/[0.02] text-black/60 dark:text-white/50 hover:border-blue-500/30 hover:bg-blue-500/[0.03]"
						}`}
					>
						{pl.icon}
						{pl.label}
					</button>
				))}
			</div>

			{/* Panel */}
			<div class="rounded-2xl border border-black/10 dark:border-white/10 overflow-hidden">
				{/* Arch + nightly row */}
				<div class="flex flex-wrap items-center gap-2 px-6 py-4 border-b border-black/8 dark:border-white/8 bg-black/[0.02] dark:bg-white/[0.02]">
					<span class="hidden sm:inline text-xs text-black/40 dark:text-white/30 font-medium uppercase tracking-wide mr-2">
						Arch
					</span>
					{p.arches.map((a) => (
						<button
							key={a}
							type="button"
							onClick={() => setArch(a)}
							class={`cursor-pointer px-3 py-1 rounded-lg text-sm border transition-all ${
								arch === a
									? "border-blue-500/50 bg-blue-500/[0.06] text-blue-400"
									: "border-black/10 dark:border-white/10 text-black/50 dark:text-white/40 hover:border-blue-500/30 hover:text-blue-400"
							}`}
						>
							{a}
						</button>
					))}
					<button
						type="button"
						onClick={() => setNightly((n) => !n)}
						class={`cursor-pointer ml-auto px-3 py-1 rounded-lg text-sm border transition-all ${
							nightly
								? "border-amber-500/50 bg-amber-500/[0.06] text-amber-400"
								: "border-black/10 dark:border-white/10 text-black/50 dark:text-white/40 hover:border-amber-500/30 hover:text-amber-400"
						}`}
					>
						nightly
					</button>
				</div>

				{/* Methods */}
				<div class="divide-y divide-black/[0.06] dark:divide-white/[0.06]">
					{ms.map((m) => {
						const cmd = applyNightly(m.command);
						return (
							<div key={m.id} class="p-6 flex flex-col gap-3">
								<div class="flex items-center gap-2 text-sm font-semibold">
									{m.icon}
									{m.label}
								</div>
								<div class="flex items-center gap-2 px-4 py-3 rounded-lg bg-black/5 dark:bg-white/5 border border-black/8 dark:border-white/8 font-mono text-sm min-w-0">
									<span class="text-blue-400 select-none shrink-0">
										$
									</span>
									<code class="text-gray-800 dark:text-white flex-1 min-w-0 overflow-x-auto whitespace-nowrap">
										{cmd}
									</code>
									<CopyButton text={cmd} />
								</div>
								{m.note && (
									<p class="text-xs text-black/40 dark:text-white/35">
										{m.note}
									</p>
								)}
							</div>
						);
					})}
				</div>

				{/* Footer */}
				<div class="px-6 py-4 border-t border-black/8 dark:border-white/8 flex flex-wrap items-center justify-between gap-2 text-xs text-black/35 dark:text-white/30">
					<span>
						Already installed? Run{" "}
						<code class="text-blue-400">lde upgrade</code>
					</span>
					<a
						href={GITHUB_RELEASES_URL}
						target="_blank"
						rel="noopener noreferrer"
						class="flex items-center gap-1 hover:text-black/60 dark:hover:text-white/50 transition-colors"
					>
						Manual download
						<svg
							xmlns="http://www.w3.org/2000/svg"
							width="10"
							height="10"
							viewBox="0 0 24 24"
							fill="none"
							stroke="currentColor"
							stroke-width="2.5"
							stroke-linecap="round"
							stroke-linejoin="round"
						>
							<path d="M7 7h10v10" />
							<path d="M7 17 17 7" />
						</svg>
					</a>
				</div>
			</div>
		</div>
	);
}
