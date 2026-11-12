//
//  KeystrokeTypingTests.swift
//  SliceCoreTests
//
//  Created by rit3zh CX on 11/12/26.
//

import CoreImage
import ImageIO
@testable import SliceCore
import XCTest

final class KeystrokeTypingTests: XCTestCase {
    private func typed(_ t: Double, _ key: String) -> KeyPress { KeyPress(t: t, modifiers: "", key: key) }

    private func timeline(_ presses: [KeyPress], show: KeystrokeSettings.Show = .typing, hold: Double = 1.4,
                          layout: KeystrokeSettings.Layout = .single) -> KeystrokeTimeline {
        var s = KeystrokeSettings()
        s.show = show
        s.hold = hold
        s.layout = layout
        return KeystrokeTimeline(presses: presses, settings: s)
    }

    // MARK: - Recording

    func testTypedCharactersAreKeptOnlyWhenAskedFor() {
        func make(_ text: String?, code: UInt16 = 0, shift: Bool = false, command: Bool = false) -> KeyPress? {
            KeyPress.make(t: 0, keyCode: code, characters: "a", text: text, control: false, option: false, shift: shift, command: command)
        }
        XCTAssertNil(make(nil))
        XCTAssertEqual(make("a"), KeyPress(t: 0, modifiers: "", key: "a"))
        XCTAssertEqual(make("A", shift: true), KeyPress(t: 0, modifiers: "", key: "A"), "shift is in the character")
        XCTAssertEqual(make("a", command: true)?.label, "⌘ A", "still a shortcut")
        XCTAssertEqual(make(" ", code: 49)?.key, "Space")
        XCTAssertNil(make("\u{7f}"), "control characters aren't text")
        XCTAssertTrue(KeyPress(t: 0, modifiers: "", key: "a").isTyped)
        XCTAssertFalse(KeyPress(t: 0, modifiers: "", key: "esc").isTyped)
        XCTAssertFalse(KeyPress(t: 0, modifiers: "⌘", key: "K").isTyped)
    }

    // MARK: - Timeline

    func testTypingMakesOneLineThatBackspaceEdits() {
        let presses = [typed(1, "h"), typed(1.1, "e"), typed(1.2, "y"), typed(1.3, "Space"), typed(1.4, "y"), typed(1.5, "o"),
                       typed(1.6, "⌫")]
        let t = timeline(presses)
        XCTAssertEqual(t.groups.count, 1)
        XCTAssertEqual(t.states(at: 1.25).last?.label, "hey")
        XCTAssertEqual(t.states(at: 1.55).last?.label, "hey yo")
        XCTAssertEqual(t.states(at: 1.65).last?.label, "hey yo", "the o still going")
        XCTAssertEqual(t.states(at: 1.8).last?.label, "hey y")
        XCTAssertEqual(t.states(at: 1.8).last?.isText, true)
        XCTAssertEqual(t.states(at: 1.8).last?.count, 1)
    }

    func testAPauseStartsANewLineAndShortcutsBreakIt() {
        let presses = [typed(1, "a"), typed(1.1, "b"), typed(4, "c"), KeyPress(t: 4.2, modifiers: "⌘", key: "S"), typed(4.3, "d")]
        let t = timeline(presses)
        XCTAssertEqual(t.groups.map(\.label), ["a", "c", "⌘ S", "d"])
        XCTAssertEqual(t.states(at: 1.2).last?.label, "ab")
    }

    func testALongLineKeepsItsNewestLettersWithoutAnEllipsis() {
        let presses = (0 ..< 120).map { typed(1 + Double($0) * 0.05, $0 % 7 == 6 ? "Space" : "x") }
        let label = timeline(presses).states(at: 7.1).last?.label
        XCTAssertEqual(label?.count, KeystrokeTimeline.lineLength)
        XCTAssertFalse(label?.contains("…") ?? true, "the renderer fades the front instead")
    }

    func testTypingIsShownOnlyWhenChosen() {
        let presses = [typed(1, "a"), typed(1.1, "Space"), KeyPress(t: 3, modifiers: "", key: "esc"), KeyPress(t: 5, modifiers: "⌘", key: "K")]
        XCTAssertEqual(timeline(presses, show: .shortcuts).groups.map(\.label), ["⌘ K"])
        XCTAssertEqual(timeline(presses, show: .keys).groups.map(\.label), ["esc", "⌘ K"], "no typing, no lone spaces")
        XCTAssertEqual(timeline(presses, show: .typing).groups.map(\.label), ["a", "esc", "⌘ K"])
    }

    func testNewLettersComeIntoFocus() throws {
        let t = timeline([typed(1, "a"), typed(1.1, "b"), typed(1.15, "c")])
        let s = try XCTUnwrap(t.states(at: 1.25).last)
        XCTAssertEqual(s.label, "abc")
        XCTAssertNil(s.reveal[0], "typed long enough ago to have settled")
        XCTAssertEqual(try XCTUnwrap(s.reveal[1]), 0.15 / KeystrokeTimeline.typeIn, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(s.reveal[2]), 0.1 / KeystrokeTimeline.typeIn, accuracy: 0.001)
        XCTAssertEqual(t.states(at: 1.6).last?.reveal, [:])
    }

    func testABackspacedLetterFadesOutRatherThanVanishing() throws {
        let t = timeline([typed(1, "a"), typed(1.2, "b"), typed(1.6, "⌫")])
        let leaving = try XCTUnwrap(t.states(at: 1.65).last)
        XCTAssertEqual(leaving.label, "ab", "still drawn while it goes")
        XCTAssertEqual(try XCTUnwrap(leaving.reveal[1]), 1 - 0.05 / KeystrokeTimeline.typeOut, accuracy: 0.001)
        let gone = try XCTUnwrap(t.states(at: 1.6 + KeystrokeTimeline.typeOut + 0.01).last)
        XCTAssertEqual(gone.label, "a")
        XCTAssertEqual(gone.reveal, [:])
    }

    func testHeldBackspaceLetsEachLetterGoInTurn() throws {
        let t = timeline([typed(1, "a"), typed(1.1, "b"), typed(1.2, "c"), typed(2, "⌫"), typed(2.05, "⌫")])
        let s = try XCTUnwrap(t.states(at: 2.1).last)
        XCTAssertEqual(s.label, "abc")
        XCTAssertEqual(try XCTUnwrap(s.reveal[2]), 1 - 0.1 / KeystrokeTimeline.typeOut, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(s.reveal[1]), 1 - 0.05 / KeystrokeTimeline.typeOut, accuracy: 0.001)
        XCTAssertGreaterThan(s.reveal[1]!, s.reveal[2]!, "the first deleted is further gone")
    }

    func testTypingAgainAfterBackspaceShowsTheNewLetter() throws {
        let t = timeline([typed(1, "a"), typed(1.1, "b"), typed(1.5, "⌫"), typed(1.55, "x")])
        let s = try XCTUnwrap(t.states(at: 1.6).last)
        XCTAssertEqual(s.label, "axb", "the b still fading, after the x")
        XCTAssertNotNil(s.reveal[1], "x coming in")
        XCTAssertEqual(try XCTUnwrap(s.reveal[2]), 1 - 0.1 / KeystrokeTimeline.typeOut, accuracy: 0.001, "b going")
        XCTAssertEqual(t.states(at: 1.5 + KeystrokeTimeline.typeOut + 0.01).last?.label, "ax")
    }

    func testCorrectionsChangeTheBarGradually() throws {
        // A typo, two quick backspaces and the fix, played at 60 fps: the bar never jumps more than a letter's sliver.
        let presses = typing("helo") + [typed(1.5, "⌫"), typed(1.56, "⌫"), typed(1.62, "l"), typed(1.7, "o")]
        let t = timeline(presses)
        let renderer = FrameRenderer()
        let f: CGFloat = 40
        var widths: [CGFloat] = []
        for frame in 0 ... 90 {
            let time = 1.3 + Double(frame) / 60
            guard let s = t.states(at: time).last,
                  let image = renderer.typedLineImage(s.label, reveal: s.reveal, style: .dark, fontSize: f, maxWidth: 4000) else { continue }
            widths.append(image.extent.width)
        }
        let steps = zip(widths, widths.dropFirst()).map { abs($1 - $0) }
        XCTAssertLessThan(steps.max() ?? 0, f * 0.3, "\(widths.map { Int($0) })")
    }

    // MARK: - Hidden words

    private func typing(_ text: String, from start: Double = 1) -> [KeyPress] {
        text.enumerated().map { i, c in typed(start + Double(i) * 0.08, c == " " ? "Space" : String(c)) }
    }

    func testHiddenWordsAreDotsFromTheirFirstLetter() throws {
        var s = KeystrokeSettings()
        s.show = .typing
        s.hiddenWords = ["Secret"]
        let presses = typing("my secret, ok")
        let t = KeystrokeTimeline(presses: presses, settings: s)
        // "my se": the word isn't finished, but it becomes "secret,", so it's already dots.
        XCTAssertEqual(t.states(at: presses[4].t + 0.01).last?.label, "my ••")
        XCTAssertEqual(t.states(at: presses.last!.t + 0.3).last?.label, "my ••••••• ok")
        let words = KeystrokeTimeline(presses: presses, settings: { var p = s; p.hiddenWords = []; return p }())
        XCTAssertEqual(words.states(at: presses.last!.t + 0.3).last?.label, "my secret, ok", "nothing hidden")
    }

    func testOnlyTheWordItselfIsHidden() {
        let hidden: Set<String> = ["cat"]
        XCTAssertEqual(KeystrokeTimeline.masking("a cat category", finally: "a cat category", hidden: hidden), "a ••• category")
        XCTAssertEqual(KeystrokeTimeline.masking("a ca", finally: "a category", hidden: hidden), "a ca", "becomes another word")
    }

    func testTypedWordsListsEachWordOnce() {
        let presses = typing("Hello there, hello again") + typing("bye", from: 10)
        XCTAssertEqual(KeystrokeTimeline.typedWords(in: presses, hold: 1.4), ["hello", "there", "again", "bye"])
    }

    func testRevealFollowsALineScrollingOffTheFront() throws {
        let presses = (0 ..< 120).map { typed(1 + Double($0) * 0.3, "x") }
        let s = try XCTUnwrap(timeline(presses).states(at: 1 + 119 * 0.3 + 0.05).last)
        XCTAssertEqual(s.label.count, KeystrokeTimeline.lineLength)
        XCTAssertEqual(Set(s.reveal.keys), [KeystrokeTimeline.lineLength - 1], "the newest letter, at the end")
    }

    func testStackedPressesStayUpAndStepAway() {
        let presses = [KeyPress(t: 1, modifiers: "⌘", key: "C"), KeyPress(t: 1.5, modifiers: "⌘", key: "V"),
                       KeyPress(t: 2, modifiers: "⌘", key: "Z")]
        let single = timeline(presses, show: .shortcuts)
        XCTAssertEqual(single.states(at: 2.6).map(\.label), ["⌘ Z"], "one at a time")
        let stack = timeline(presses, show: .shortcuts, layout: .stack)
        let states = stack.states(at: 2.6)
        XCTAssertEqual(states.map(\.label), ["⌘ C", "⌘ V", "⌘ Z"], "oldest first")
        XCTAssertEqual(states.map(\.slot), [2, 1, 0])
        XCTAssertEqual(stack.states(at: 2.75).map(\.label), ["⌘ V", "⌘ Z"], "each leaves on its own time")
        XCTAssertEqual(stack.states(at: 2.75).map(\.slot), [1, 0], "and the others stay where they are")
        let arriving = stack.states(at: 2 + KeystrokeTimeline.inDuration / 2)
        XCTAssertGreaterThan(arriving[1].slot, 0)
        XCTAssertLessThan(arriving[1].slot, 1, "pushed up as the newest comes in")
    }

    func testStackHoldsAtMostItsLimit() {
        let presses = (0 ..< 9).map { KeyPress(t: 1 + Double($0) * 0.1, modifiers: "⌘", key: String($0)) }
        XCTAssertEqual(timeline(presses, show: .shortcuts, layout: .stack).states(at: 2).count, KeystrokeTimeline.stackLimit)
    }

    // MARK: - Settings

    func testOlderProjectsKeepTheirSingleKeys() throws {
        let on = try JSONDecoder().decode(KeystrokeSettings.self, from: Data(#"{"singleKeys": true}"#.utf8))
        XCTAssertEqual(on.show, .keys)
        XCTAssertEqual(on.style, .dark)
        XCTAssertEqual(on.alignment, .center)
        let off = try JSONDecoder().decode(KeystrokeSettings.self, from: Data(#"{"singleKeys": false}"#.utf8))
        XCTAssertEqual(off.show, .shortcuts)
    }

    func testSettingsSurviveASaveAndOlderVersionsStillReadSingleKeys() throws {
        var s = KeystrokeSettings()
        s.show = .typing
        s.style = .keycaps
        s.alignment = .leading
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(KeystrokeSettings.self, from: data), s)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["singleKeys"] as? Bool, true)
    }

    func testSingleKeysSwitchKeepsTyping() {
        var s = KeystrokeSettings()
        s.singleKeys = true
        XCTAssertEqual(s.show, .keys)
        s.show = .typing
        s.singleKeys = true
        XCTAssertEqual(s.show, .typing)
        s.singleKeys = false
        XCTAssertEqual(s.show, .shortcuts)
    }

    // MARK: - Drawing

    func testAlignmentPinsToTheEdges() {
        let out = CGSize(width: 1920, height: 1080), size = CGSize(width: 200, height: 80)
        let inset = FrameRenderer.keycapInset(out)
        func rect(_ a: KeystrokeSettings.Alignment) -> CGRect {
            FrameRenderer.keycapRect(size: size, position: .bottom, alignment: a, clearance: 0, camera: nil, output: out)
        }
        XCTAssertEqual(rect(.leading).minX, inset)
        XCTAssertEqual(rect(.center).midX, 960)
        XCTAssertEqual(rect(.trailing).maxX, 1920 - inset)
        XCTAssertEqual(rect(.leading).minY, rect(.trailing).minY)
    }

    func testEveryStyleDraws() throws {
        let f: CGFloat = 40
        let m = FrameRenderer.keycapMargin(f)
        var widths: [KeystrokeSettings.Style: CGFloat] = [:]
        for style in KeystrokeSettings.Style.allCases {
            let image = try XCTUnwrap(FrameRenderer.keycapImage("⇧⌘ P", count: 2, style: style, fontSize: f))
            widths[style] = image.extent.width - 2 * m
            XCTAssertEqual(image.extent.height - 2 * m, f * 2, accuracy: 1, "\(style)")
        }
        XCTAssertGreaterThan(widths[.keycaps]!, widths[.dark]!, "a key each")
        XCTAssertLessThan(widths[.minimal]!, widths[.dark]!, "no plate")
        XCTAssertEqual(FrameRenderer.keycapTokens("⇧⌘ P"), ["⇧", "⌘", "P"])
        XCTAssertEqual(FrameRenderer.keycapTokens("esc"), ["esc"])
    }

    func testALongTypedLineFitsTheFrame() throws {
        let line = String(repeating: "typing quickly ", count: 8)
        let image = try XCTUnwrap(FrameRenderer.keycapImage(line, count: 1, isText: true, fontSize: 40, maxWidth: 900))
        XCTAssertLessThanOrEqual(image.extent.width - 2 * FrameRenderer.keycapMargin(40), 901)
    }

    func testTypedLinePlateGrowsAsALetterComesIn() throws {
        let renderer = FrameRenderer()
        func width(_ p: Double?) throws -> CGFloat {
            let reveal = p.map { [4: $0] } ?? [:]
            return try XCTUnwrap(renderer.typedLineImage("Hello", reveal: reveal, style: .dark, fontSize: 40, maxWidth: 2000)).extent.width
        }
        let start = try width(0), half = try width(0.5), done = try width(nil)
        XCTAssertLessThan(start, half)
        XCTAssertLessThan(half, done)
        XCTAssertEqual(try width(1), done, accuracy: 1)
        let image = try XCTUnwrap(renderer.typedLineImage("Hello", reveal: [:], style: .minimal, fontSize: 40, maxWidth: 2000))
        XCTAssertEqual(image.extent.height, 80 + 2 * FrameRenderer.keycapMargin(40), accuracy: 0.5)
    }

    func testALongLineStopsGrowingAndScrolls() throws {
        let renderer = FrameRenderer()
        let f: CGFloat = 40
        func width(_ text: String) throws -> CGFloat {
            try XCTUnwrap(renderer.typedLineImage(text, reveal: [:], style: .dark, fontSize: f, maxWidth: 4000)).extent.width
        }
        let short = try width("hi there")
        let long = try width(String(repeating: "typing fast ", count: 4))
        let longer = try width(String(repeating: "typing fast ", count: 6))
        XCTAssertLessThan(short, long)
        XCTAssertEqual(long, longer, accuracy: 1, "a set width once it scrolls")
        let pad = f * 0.66, m = FrameRenderer.keycapMargin(f)
        XCTAssertEqual(long - 2 * m, f * FrameRenderer.typedWindow + 2 * pad, accuracy: 1)
    }

    func testScrolledLineFadesItsLeadingEdge() throws {
        let renderer = FrameRenderer()
        let f: CGFloat = 40
        let image = try XCTUnwrap(renderer.typedLineImage(String(repeating: "W", count: 60), reveal: [:], style: .minimal,
                                                          fontSize: f, maxWidth: 4000))
        func alpha(at x: CGFloat) -> UInt8 {
            var px = [UInt8](repeating: 0, count: 4)
            CIContext().render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: f, width: 1, height: 1), format: .RGBA8,
                               colorSpace: nil)
            return px[3]
        }
        let w = image.extent.maxX - FrameRenderer.keycapMargin(f)
        // Columns across the glyphs: the most ink in a band near each edge.
        let start = (0 ..< 8).map { alpha(at: CGFloat($0) * 2 + 1) }.max()!
        let end = (0 ..< 8).map { alpha(at: w - CGFloat($0) * 2 - 30) }.max()!
        XCTAssertLessThan(Int(start) * 3, Int(end), "faded at the front, solid at the end")
    }

    /// Set RENDER_OUT to a directory to also write PNGs for eyeballing.
    func testRenderStyleSamples() throws {
        guard let outDir = ProcessInfo.processInfo.environment["RENDER_OUT"].map({ URL(fileURLWithPath: $0) }) else { return }
        let context = CIContext()
        let samples: [(String, String, Bool)] = [("⇧⌘ P", "shortcut", false), ("esc", "key", false), ("Hello, world", "typed", true),
                                                 ("to seem this who how school something about typing fast", "long", true)]
        let renderer = FrameRenderer()
        for style in KeystrokeSettings.Style.allCases {
            for (label, name, text) in samples {
                let image = try XCTUnwrap(text
                    ? renderer.typedLineImage(label, reveal: [label.count - 1: 0.35, label.count - 2: 0.7], style: style, fontSize: 48,
                                              maxWidth: 2000)
                    : FrameRenderer.keycapImage(label, count: name == "shortcut" ? 3 : 1, style: style, fontSize: 48))
                let backed = image.composited(over: CIImage(color: CIColor(red: 0.45, green: 0.4, blue: 0.85)).cropped(to: image.extent))
                let cg = try XCTUnwrap(context.createCGImage(backed, from: image.extent))
                let url = outDir.appendingPathComponent("keys-\(style.rawValue)-\(name).png")
                let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, cg, nil)
                XCTAssertTrue(CGImageDestinationFinalize(dest))
            }
        }
    }
}
