import { useState } from "preact/hooks";

interface CopyButtonProps {
	getText: () => string;
	/** Optional label rendered next to the icon; icon-only when omitted. */
	label?: string;
	/** Label shown while the copy feedback is visible (defaults to `label`). */
	copiedLabel?: string;
	/** Extra classes replacing the default subtle icon-button styling. */
	className?: string;
}

export function CopyButton({
	getText,
	label,
	copiedLabel,
	className = "p-1.5 rounded-md opacity-40 hover:opacity-100 transition-opacity",
}: CopyButtonProps) {
	const [copied, setCopied] = useState(false);

	const handleCopy = () => {
		navigator.clipboard.writeText(getText()).then(() => {
			setCopied(true);
			setTimeout(() => setCopied(false), 2000);
		});
	};

	return (
		<button
			type="button"
			onClick={handleCopy}
			class={`inline-flex items-center gap-1.5 cursor-pointer ${className}`}
			title={copied ? "Copied to clipboard" : (label ?? "Copy to clipboard")}
		>
			{copied ? (
				<svg
					xmlns="http://www.w3.org/2000/svg"
					class="w-4 h-4 text-green-400"
					viewBox="0 0 24 24"
					fill="none"
					stroke="currentColor"
					stroke-width="2.5"
					stroke-linecap="round"
					stroke-linejoin="round"
				>
					<title>Copied</title>
					<polyline points="20 6 9 17 4 12" />
				</svg>
			) : (
				<svg
					xmlns="http://www.w3.org/2000/svg"
					class="w-4 h-4"
					viewBox="0 0 24 24"
					fill="none"
					stroke="currentColor"
					stroke-width="2.5"
					stroke-linecap="round"
					stroke-linejoin="round"
				>
					<title>Copy</title>
					<rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
					<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
				</svg>
			)}
			{label && (
				<span class={`text-sm ${copied ? "text-green-400" : ""}`}>
					{copied ? (copiedLabel ?? label) : label}
				</span>
			)}
		</button>
	);
}
