import { CopyButton } from "./CopyButton";

interface CopyPageButtonProps {
	/** Raw markdown body of the page to copy. */
	markdown: string;
}

export default function CopyPageButton({ markdown }: CopyPageButtonProps) {
	return (
		<CopyButton
			getText={() => markdown}
			label="Copy page"
			copiedLabel="Copied"
			className="ml-auto w-30 flex items-center justify-evenly px-3.5 py-2 border border-black/10 dark:border-white/10 text-sm font-medium text-black/40 dark:text-white/40 hover:text-black hover:border-black/30 hover:bg-black/5 dark:hover:text-white dark:hover:border-white/30 dark:hover:bg-white/5 transition-colors"
		/>
	);
}
