import { site } from "@/lib/site";

export const license = {
	name: "Slice Source-Available License",
	type: "Source-available",
	version: "1.0",
	updated: "October 16, 2026",
	copyright: "Copyright © 2026 rit3zh",
	repo: site.repo,
	contact: site.author.url,
};

export type Component = { name: string; use: string; license: string; url: string; file?: string };

export type Block = { p: string } | { list: string[] } | { components: Component[] };

export const COMPONENTS: Component[] = [
	{
		name: "FluidAudio",
		use: "Runs Parakeet transcription on the Neural Engine",
		license: "Apache License 2.0",
		url: "https://github.com/FluidInference/FluidAudio",
	},
	{
		name: "SmoothGradient",
		use: "Smooth gradient interpolation, by Ramon Torres",
		license: "MIT License",
		url: "https://github.com/raymondjavaxx/SmoothGradient",
	},
	{
		name: "BorderBeamKit",
		use: "The capture bar's animated border, a SwiftUI port of border-beam by Jakub Antalik",
		license: "Credited to the original author",
		url: "https://beam.jakubantalik.com",
	},
	{
		name: "Sparkle",
		use: "In-app updates from Slice's GitHub releases",
		license: "MIT License",
		url: "https://github.com/sparkle-project/Sparkle",
	},
	{
		name: "Safari mockup",
		use: "The browser window drawn around screen recordings, after the Safari component in Magic UI",
		license: "MIT License",
		url: "https://github.com/magicuidesign/magicui",
	},
	{
		name: "3D device models",
		use: "The iPhones and MacBook in the 3D editor, by the Sketchfab artists named in the credits",
		license: "CC BY 4.0, except the iPhone 18 Pro Max (Sketchfab Standard)",
		url: "/credits",
		file: "Sources/SliceCore/Resources/Models/CREDITS.txt",
	},
	{
		name: "Keyboard sound packs",
		use: "Cherry MX Blue (Hai Nguyen) and Holy Panda (Thomas Lai) keystroke sounds",
		license: "MIT License",
		url: "https://github.com/rit3zh/slice/tree/main/Sources/SliceCore/Resources/Sounds/Keyboards",
	},
	{
		name: "Apex Pro sound pack",
		use: "Keystroke sounds",
		license: "GNU GPL 3.0",
		url: "https://github.com/rit3zh/slice/tree/main/Sources/SliceCore/Resources/Sounds/Keyboards/apex-pro",
	},
	{
		name: "DeepFilterNet3",
		use: "Voice enhancement. Downloaded on request, not bundled",
		license: "MIT or Apache License 2.0",
		url: "https://github.com/Rikorose/DeepFilterNet",
	},
	{
		name: "Parakeet Ultra 0.6B",
		use: "Transcription model. Downloaded on request, not bundled",
		license: "CC BY 4.0",
		url: "https://huggingface.co/FluidInference/parakeet-ultra-coreml",
	},
];

export type Clause = { id: string; title: string; body: Block[] };

export const CLAUSES: Clause[] = [
	{
		id: "purpose",
		title: "Purpose",
		body: [
			{
				p: "Slice is source-available software. Its source code is published so that people can use it, learn from it, change it for themselves, and help improve it. This license grants those freedoms while keeping the right to sell or commercially redistribute Slice with the Licensor.",
			},
			{
				p: "Slice is not open source software as defined by the Open Source Initiative, because this license restricts commercial redistribution.",
			},
		],
	},
	{
		id: "definitions",
		title: "Definitions",
		body: [
			{
				list: [
					"“Licensor” means rit3zh, the copyright holder of Slice.",
					"“Software” means Slice, including its source code, compiled applications, documentation and other files published in the official repository.",
					"“You” means the individual or entity exercising the rights granted by this license.",
					"“Modified Version” means any work that contains the Software, or a substantial part of it, with changes.",
					"“Distribute” means to make the Software or a Modified Version available to anyone else, by any means.",
					"“Commercial” means intended for, or directed toward, payment, commercial advantage or monetary compensation, including through sales, subscriptions, advertising or bundling with a paid product or service.",
				],
			},
		],
	},
	{
		id: "personal-use",
		title: "Personal and professional use",
		body: [
			{
				p: "You may download, install and run the Software, free of charge, on any device you own or control.",
			},
			{
				p: "This includes using the Software at work, inside a company or organization, and to make videos for paid work. The restrictions in sections 7 to 9 apply to distributing the Software itself, not to using it.",
			},
			{
				p: "Recordings, videos and other content you create with the Software belong to you. This license places no restrictions on how you use them.",
			},
		],
	},
	{
		id: "source-access",
		title: "Inspecting and cloning the source",
		body: [
			{
				p: "You may view, download, clone and fork the source code from the official repository, build it yourself, and study how it works.",
			},
		],
	},
	{
		id: "modifications",
		title: "Modifications",
		body: [
			{
				p: "You may modify the Software and run your Modified Version for your own use.",
			},
			{
				p: "You may share the source code of a Modified Version for free, for example as a public fork of the official repository, as long as you:",
			},
			{
				list: [
					"keep this license and the copyright notice with it;",
					"clearly mark it as modified and unofficial, and say what you changed; and",
					"do not charge for it or use it for a Commercial purpose.",
				],
			},
			{
				p: "Distributing a Modified Version commercially is not permitted unless the Licensor has given you written permission under section 12.",
			},
		],
	},
	{
		id: "contributions",
		title: "Contributions",
		body: [
			{
				p: "You may propose changes to the Software by opening issues and submitting pull requests to the official repository.",
			},
			{
				p: "By submitting a contribution, you confirm that you have the right to submit it, and you grant the Licensor a perpetual, worldwide, non-exclusive, royalty-free license to use, modify and distribute that contribution as part of the Software under this license or any later license the Licensor chooses.",
			},
			{
				p: "You keep the copyright in your contribution. Submitting a pull request does not transfer ownership of any code to you or to the Licensor beyond the contribution itself, and gives you no rights in other parts of the Software beyond those this license already grants.",
			},
			{
				p: "How to contribute is described in CONTRIBUTING.md in the official repository.",
			},
		],
	},
	{
		id: "no-commercial-redistribution",
		title: "No commercial redistribution",
		body: [
			{
				p: "You may not Distribute the Software, or a Modified Version, for a Commercial purpose. This includes publishing it in a paid app store listing, bundling it with a paid product or service, or offering it behind a paywall or subscription.",
			},
		],
	},
	{
		id: "no-resale",
		title: "No resale as a standalone application",
		body: [
			{
				p: "You may not sell, license, rent or otherwise charge for the Software or a Modified Version as a standalone application, whether as source code or as a compiled binary.",
			},
		],
	},
	{
		id: "no-rebranding",
		title: "No rebranding as a competing product",
		body: [
			{
				p: "You may not rename or rebrand the Software or a Modified Version and offer it to others as your own screen recording or video editing product, whether or not you charge for it.",
			},
		],
	},
	{
		id: "ownership",
		title: "Ownership and attribution",
		body: [
			{
				p: "The Licensor keeps all copyright and other rights in the Software that this license does not expressly grant. This license does not grant any right to use the Slice name, icon or other marks, except to accurately say where the Software comes from.",
			},
			{
				p: "You must keep this license and the copyright notice with every copy of the Software and every Modified Version.",
			},
		],
	},
	{
		id: "third-party",
		title: "Third-party components",
		body: [
			{
				p: "Some parts of the Software were made by others and are under their own licenses. This license does not apply to them; their own licenses do, and they take precedence for those files.",
			},
			{ components: COMPONENTS },
			{
				p: "Apple, iPhone, Mac and macOS are trademarks of Apple Inc. Slice is an independent project and is not affiliated with or endorsed by Apple.",
			},
		],
	},
	{
		id: "commercial-permission",
		title: "Commercial permission",
		body: [
			{
				p: "If you want to use the Software in a way this license does not allow, including commercial redistribution, ask the Licensor. Permission is only valid if it is given in writing, and only for what it expressly covers.",
			},
			{
				p: "To ask, open an issue on the official repository or message @rit3zh on X.",
			},
		],
	},
	{
		id: "no-warranty",
		title: "No warranty",
		body: [
			{
				p: "THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE LICENSOR OR CONTRIBUTORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.",
			},
		],
	},
	{
		id: "termination",
		title: "Violations and termination",
		body: [
			{
				p: "If you break any term of this license, your rights under it end automatically. You must then stop using and distributing the Software and any Modified Version.",
			},
			{
				p: "If it is your first violation and you fix it within 30 days of being notified by the Licensor, your rights are reinstated.",
			},
		],
	},
];

export type Question = { q: string; a: string };

export const FAQ: Question[] = [
	{
		q: "Can I use Slice for personal use?",
		a: "Yes. You can download, install and run Slice for free on any device you own or control, and the videos you make with it are yours (section 3).",
	},
	{
		q: "Can I use Slice at work?",
		a: "Yes. You can use it at a company and to make videos for paid work. The restrictions only cover selling or redistributing Slice itself (section 3).",
	},
	{
		q: "Can I modify the source code?",
		a: "Yes, for your own use. You can clone the repository, change the code, build it and run your version yourself (sections 4 and 5).",
	},
	{
		q: "Can I submit pull requests?",
		a: "Yes. Contributions are welcome through the official repository. You keep the copyright in what you contribute and grant the Licensor a license to use it in Slice (section 6).",
	},
	{
		q: "Can I redistribute a modified version?",
		a: "Not commercially. Commercial distribution of Slice or a modified version needs written permission (sections 7 and 12). You can share a modified version for free, in source form, if it keeps this license, is marked as unofficial and says what changed (section 5).",
	},
	{
		q: "Can I sell an application built from Slice?",
		a: "No. You can't sell Slice or a modified version as a standalone application, or rebrand it as your own product (sections 8 and 9), unless the Licensor gives you written permission.",
	},
	{
		q: "How do I get permission for commercial redistribution?",
		a: "Open an issue on the repository or message @rit3zh on X. Permission only counts if it's given in writing, and only covers what it says (section 12).",
	},
	{
		q: "What happens if someone violates the license?",
		a: "Their rights under the license end automatically, and they must stop using and distributing Slice and any modified version. A first violation fixed within 30 days of notice is forgiven (section 14).",
	},
];

export function licenseText() {
	const header = [license.name, `Version ${license.version}, ${license.updated}`, license.copyright];
	const clauses = CLAUSES.map((clause, i) => {
		const body = clause.body.flatMap((block) => {
			if ("p" in block) return [block.p];
			if ("list" in block) return [block.list.map((item) => `- ${item}`).join("\n")];
			return [block.components.map((c) => `- ${c.name}: ${c.use}. ${c.license}. ${c.file ? `${license.repo}/blob/main/${c.file}` : c.url}`).join("\n")];
		});
		return [`${i + 1}. ${clause.title}`, ...body].join("\n\n");
	});
	return [header.join("\n"), ...clauses].join("\n\n\n");
}
