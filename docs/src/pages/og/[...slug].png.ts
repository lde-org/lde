import { ImageResponse } from "@vercel/og";
import type { APIRoute, GetStaticPaths } from "astro";
import { getCollection } from "astro:content";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join, dirname } from "node:path";

const __dir = dirname(fileURLToPath(import.meta.url));

const logoDataUri = (() => {
	const b64 = readFileSync(
		join(__dir, "../../../../public/lpm-small-text-nospace.svg"),
	).toString("base64");
	return `data:image/svg+xml;base64,${b64}`;
})();

const logoSmallDataUri = (() => {
	const b64 = readFileSync(
		join(__dir, "../../../../public/lpm-small-nospace.svg"),
	).toString("base64");
	return `data:image/svg+xml;base64,${b64}`;
})();

export const getStaticPaths: GetStaticPaths = async () => {
	const [blogPosts, docEntries] = await Promise.all([
		getCollection("blog"),
		getCollection("docs"),
	]);

	const blog = blogPosts.map((post) => ({
		params: { slug: `blog/${post.id}` },
		props: {
			title: post.data.title,
			description: post.data.description ?? "",
			date: post.data.published.toLocaleDateString("en-US", {
				year: "numeric",
				month: "long",
				day: "numeric",
			}),
			index: false,
		},
	}));

	const docs = docEntries.map((entry) => {
		const body = entry.body ?? "";
		const firstParagraph =
			body
				.split("\n")
				.find((l) => l.trim() && !l.startsWith("#"))
				?.trim() ?? "";
		return {
			params: { slug: `docs/${entry.id}` },
			props: {
				title: entry.data.title,
				description: firstParagraph,
				date: "",
				index: false,
			},
		};
	});

	const pages = [
		{
			params: { slug: "index" },
			props: {
				title: "lpm",
				description:
					"Lpm is an open-source project providing easy accessibility to a Lua runtime alongside intuitive package management for dependencies.",
				date: "",
				index: true,
			},
		},
		{
			params: { slug: "blog" },
			props: {
				title: "Blog",
				description: "News and updates from the lpm team.",
				date: "",
				index: false,
			},
		},
		{
			params: { slug: "docs" },
			props: {
				title: "Documentation",
				description: "Learn how to use lpm.",
				date: "",
				index: false,
			},
		},
		{
			params: { slug: "registry" },
			props: {
				title: "Registry",
				description: "Browse and discover Lua packages for lpm.",
				date: "",
				index: false,
			},
		},
	];

	return [...blog, ...docs, ...pages];
};

export const GET: APIRoute = async ({ props }) => {
	const { title, description, date, index } = props as {
		title: string;
		description: string;
		date: string;
		index: boolean;
	};

	if (index) {
		return new ImageResponse(
			{
				type: "div",
				props: {
					tw: "flex w-full h-full bg-[#0d1117] text-white overflow-hidden",
					style: { position: "relative" },
					children: [
						// Stars as individual divs
						{
							type: "div",
							props: {
								style: {
									position: "absolute",
									inset: 0,
									display: "flex",
								},
								children: [
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "148px",
												top: "115px",
												width: "3px",
												height: "3px",
												borderRadius: "9999px",
												background: "#3b82f6",
												opacity: "0.7",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "375px",
												top: "72px",
												width: "2px",
												height: "2px",
												borderRadius: "9999px",
												background: "#3b82f6",
												opacity: "0.6",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "595px",
												top: "188px",
												width: "3px",
												height: "3px",
												borderRadius: "9999px",
												background: "#3b82f6",
												opacity: "0.65",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "88px",
												top: "355px",
												width: "2px",
												height: "2px",
												borderRadius: "9999px",
												background: "#3b82f6",
												opacity: "0.55",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "218px",
												top: "478px",
												width: "3px",
												height: "3px",
												borderRadius: "9999px",
												background: "#3b82f6",
												opacity: "0.6",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "732px",
												top: "58px",
												width: "2px",
												height: "2px",
												borderRadius: "9999px",
												background: "#3b82f6",
												opacity: "0.5",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "955px",
												top: "598px",
												width: "3px",
												height: "3px",
												borderRadius: "9999px",
												background: "#3b82f6",
												opacity: "0.55",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "1248px",
												top: "548px",
												width: "3px",
												height: "3px",
												borderRadius: "9999px",
												background: "#3b82f6",
												opacity: "0.65",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "1295px",
												top: "195px",
												width: "3px",
												height: "3px",
												borderRadius: "9999px",
												background: "#3b82f6",
												opacity: "0.6",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "472px",
												top: "528px",
												width: "2px",
												height: "2px",
												borderRadius: "9999px",
												background: "#64748b",
												opacity: "0.6",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "58px",
												top: "8px",
												width: "1px",
												height: "1px",
												borderRadius: "9999px",
												background: "#64748b",
												opacity: "0.6",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "810px",
												top: "47px",
												width: "2px",
												height: "2px",
												borderRadius: "9999px",
												background: "#64748b",
												opacity: "0.6",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "280px",
												top: "65px",
												width: "1px",
												height: "1px",
												borderRadius: "9999px",
												background: "#64748b",
												opacity: "0.6",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "1100px",
												top: "320px",
												width: "2px",
												height: "2px",
												borderRadius: "9999px",
												background: "#64748b",
												opacity: "0.5",
											},
										},
									},
									{
										type: "div",
										props: {
											style: {
												position: "absolute",
												left: "430px",
												top: "380px",
												width: "1px",
												height: "1px",
												borderRadius: "9999px",
												background: "#64748b",
												opacity: "0.5",
											},
										},
									},
								],
							},
						},
						// Main content row (normal flow, renders on top of stars)
						{
							type: "div",
							props: {
								tw: "flex flex-row items-center justify-between w-full h-full p-16",
								children: [
									// Left
									{
										type: "div",
										props: {
											tw: "flex flex-col",
											style: { width: "560px" },
											children: [
												{
													type: "div",
													props: {
														tw: "flex flex-col text-7xl font-bold mb-6",
														children: [
															{
																type: "div",
																props: {
																	children:
																		"Lua Done",
																},
															},
															{
																type: "div",
																props: {
																	style: {
																		display:
																			"flex",
																		flexDirection:
																			"column",
																		alignSelf:
																			"flex-start",
																	},
																	children: [
																		{
																			type: "div",
																			props: {
																				children:
																					"Easy",
																			},
																		},
																		{
																			type: "div",
																			props: {
																				style: {
																					height: "4px",
																					width: "160px",
																					background:
																						"#3b82f6",
																					marginTop:
																						"4px",
																				},
																			},
																		},
																	],
																},
															},
														],
													},
												},
												{
													type: "div",
													props: {
														tw: "text-3xl text-gray-300 leading-relaxed",
														children: description,
													},
												},
											],
										},
									},
									// Right: glow + rings + logo
									{
										type: "div",
										props: {
											style: {
												width: "420px",
												height: "420px",
												display: "flex",
												alignItems: "center",
												justifyContent: "center",
												position: "relative",
											},
											children: [
												// Rings (absolute)
												{
													type: "div",
													props: {
														style: {
															position:
																"absolute",
															width: "300px",
															height: "300px",
															borderRadius:
																"9999px",
															border: "1px solid rgba(148,163,184,0.3)",
														},
													},
												},
												{
													type: "div",
													props: {
														style: {
															position:
																"absolute",
															width: "380px",
															height: "380px",
															borderRadius:
																"9999px",
															border: "1px solid rgba(148,163,184,0.15)",
														},
													},
												},
												// glow layer behind logo
												{
													type: "div",
													props: {
														style: {
															position:
																"absolute",
															width: "500px",
															height: "500px",
															borderRadius:
																"9999px",
															background:
																"radial-gradient(circle, rgba(59,130,246,0.25) 0%, rgba(59,130,246,0.1) 40%, transparent 70%)",
														},
													},
												},
												// logo on top
												{
													type: "img",
													props: {
														src: logoSmallDataUri,
														width: 200,
														height: 200,
													},
												},
											],
										},
									},
								],
							},
						},
					],
				},
			},
			{ width: 1200, height: 630 },
		);
	}

	return new ImageResponse(
		{
			type: "div",
			props: {
				tw: "flex w-full h-full bg-[#0d1117] text-white p-16",
				children: {
					type: "div",
					props: {
						tw: "flex flex-col w-full h-full justify-between",
						children: [
							{
								type: "div",
								props: {
									tw: "flex flex-col",
									children: [
										{
											type: "div",
											props: {
												tw: "text-7xl font-bold mb-4",
												children: title,
											},
										},
										date && {
											type: "div",
											props: {
												tw: "text-3xl text-gray-400 mb-4",
												children: date,
											},
										},
										description && {
											type: "div",
											props: {
												tw: "text-3xl text-gray-300 leading-relaxed mt-2",
												children: description,
											},
										},
									].filter(Boolean),
								},
							},
							{
								type: "div",
								props: {
									tw: "flex justify-end items-end",
									children: {
										type: "img",
										props: {
											src: logoDataUri,
											width: 80,
											height: 80,
										},
									},
								},
							},
						],
					},
				},
			},
		},
		{ width: 1200, height: 630 },
	);
};
