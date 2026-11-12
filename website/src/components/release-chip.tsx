"use client";

import { useEffect, useState, type CSSProperties, type ReactNode } from "react";
import Link from "next/link";
import { BorderBeam } from "border-beam";
import { site } from "@/lib/site";

function Beam({ children }: { children: ReactNode }) {
	const [mounted, setMounted] = useState(false);
	useEffect(() => setMounted(true), []);

	if (!mounted) return <div className="mx-auto mb-8 w-fit">{children}</div>;
	return (
		<BorderBeam
			size="sm"
			colorVariant="ocean"
			strength={0.8}
			duration={3.2}
			hueRange={6}
			style={{ "--beam-hue-base": "-28deg" } as CSSProperties}
			className="mx-auto mb-8 w-fit"
		>
			{children}
		</BorderBeam>
	);
}

export default function ReleaseChip() {
	return (
		<Beam>
			<Link
				href="/blog/slice-0-2-8"
				className="group/chip inline-flex h-9 items-center gap-1.5 rounded-full bg-raised px-4 text-[13.5px] font-medium text-fg inset-ring inset-ring-line transition-colors duration-200 ease-quart hover:bg-surface"
			>
				<span className="text-muted">v{site.version}</span>
				<span className="text-faint" aria-hidden>
					·
				</span>
				Now with Safari and Android mockups
				<svg
					width="10"
					height="10"
					viewBox="0 0 10 10"
					aria-hidden
					className="text-muted transition-transform duration-300 ease-settle group-hover/chip:translate-x-0.5 motion-reduce:transition-none"
				>
					<path d="M2 5h6M5.5 2.5 8 5 5.5 7.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
				</svg>
			</Link>
		</Beam>
	);
}
