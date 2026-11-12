export const site = {
	name: "Slice",
	url: (process.env.NEXT_PUBLIC_SITE_URL ?? "https://slice.rit3zh.dev").replace(/\/$/, ""),
	tagline: "Screen recorder and editor for Mac",
	description:
		"Slice is a free, native Mac screen recorder and editor. Record your screen, camera and microphone, then add auto zooms, smooth cursor, wallpapers, transitions, spotlights and captions, and blur anything private. No account, and nothing leaves your Mac.",
	author: { name: "rit3zh", url: "https://x.com/rit3zh", handle: "@rit3zh" },
	version: "0.2.8",
	repo: "https://github.com/rit3zh/slice",
	download: "https://github.com/rit3zh/slice/releases/latest",
	requirement: "macOS 15 or later",
	donate: "https://buymeacoffee.com/rit3zh",
};

export type Social = { id: "github" | "x" | "discord" | "coffee"; label: string; href: string };

export const socials: Social[] = (
	[
		{ id: "github", label: "GitHub", href: site.repo },
		{ id: "x", label: "X", href: "https://x.com/rit3zh" },
		{ id: "discord", label: "Discord", href: "" },
		{ id: "coffee", label: "Buy Me a Coffee", href: site.donate },
	] satisfies Social[]
).filter((s) => s.href);
