import { useEffect } from "preact/hooks";
import { render } from "preact";
import { CopyButton } from "./CopyButton";

export default function CodeBlocks() {
	useEffect(() => {
		document.querySelectorAll<HTMLElement>(".markdown pre").forEach((pre) => {
			// The <pre> scrolls horizontally when lines overflow, so overlay
			// chrome (copy button, language label) must live on the wrapping
			// .codeblock frame — anything inside the scroller scrolls away.
			let block = pre.parentElement;
			if (!block || !block.classList.contains("codeblock")) {
				block = document.createElement("div");
				block.className = "codeblock";
				pre.before(block);
				block.appendChild(pre);
			}
			for (const attr of ["data-language", "data-filename"]) {
				if (pre.hasAttribute(attr) && !block.hasAttribute(attr)) {
					block.setAttribute(attr, pre.getAttribute(attr)!);
				}
			}

			const code = pre.querySelector("code");
			const getText = () => (code ? code.innerText : pre.innerText);

			const container = document.createElement("div");
			container.className = "absolute right-2";
			container.style.top = "calc(1.75rem + 1rem)";
			block.appendChild(container);

			render(<CopyButton getText={getText} />, container);
		});
	}, []);

	return null;
}
