import { useEffect, useRef } from "preact/hooks";
import { render } from "preact";
import { CopyButton } from "./CopyButton";

export default function CodeBlocks() {
	useEffect(() => {
		document.querySelectorAll<HTMLElement>(".markdown pre").forEach((pre) => {
			const code = pre.querySelector("code");
			const getText = () => (code ? code.innerText : pre.innerText);

			const container = document.createElement("div");
			container.className = "absolute right-2";
			container.style.top = "calc(1.75rem + 0.5rem)";
			pre.style.position = "relative";
			pre.appendChild(container);

			render(<CopyButton getText={getText} />, container);
		});
	}, []);

	return null;
}
