// TypeKeystrokes.swift — Human-paced fork
//
// Turns UTF-8 text from stdin into real OS-level keyboard events.
//
// Base engine (inherited from keystroke-typer):
//   CGEvent.keyboardSetUnicodeString injects finished Unicode directly, bypassing
//   the input method and the clipboard. No paste event is ever generated, so pages
//   that block `paste` / `onpaste` never see one. Events go to the HID tap, so
//   `event.isTrusted === true` in the browser.
//
// Human engine (this fork), enabled with --human:
//   1. Text is split into ASCII words / literals / newlines.
//   2. Each word samples a WPM from [wpm-min, wpm-max] (default 75-100);
//      per-character delay is 60000 / (5 * wpm) ms with +/-15% drift.
//   3. A word longer than --long-word has --pause-chance % odds of a
//      --pause-min..--pause-max ms hesitation BEFORE its first character.
//   4. Every 10-20 words (random per cycle) there is a --phrase-pause ms breath.
//   5. Each word has --typo-chance % odds of one QWERTY-neighbour substitution.
//      The whole wrong word is typed, deleted with N Backspaces, then retyped.
//   6. Esc aborts: a listen-only CGEventTap watches for kVK_Escape while all
//      waits are cut into 10 ms slices, so even a long pause is interruptible.
//
// Build:
//   swiftc -O -o type-keystrokes-helper TypeKeystrokes.swift -framework Carbon
//
// Options:
//   --focus-delay <ms>   Wait before typing (let Raycast hand focus back). 700
//   --interval <ms>      Classic-mode delay between characters. 12
//   --jitter <ms>        Classic-mode extra 0..N ms per character. 0
//   --human              Enable human pacing (default: classic engine)
//   --wpm-min <int>      Lower WPM bound. 75
//   --wpm-max <int>      Upper WPM bound. 100
//   --long-word <int>    Word length threshold, strictly greater. 10
//   --pause-chance <%>   Chance to hesitate before a long word. 50
//   --pause-min <ms>     Minimum hesitation. 500
//   --pause-max <ms>     Maximum hesitation. 3000
//   --phrase-min <int>   Minimum words between breath pauses. 10
//   --phrase-max <int>   Maximum words between breath pauses. 20
//   --phrase-pause <ms>  Duration of a breath pause. 1000
//   --typo-chance <%>    Chance per word of a typo + full retype. 5
//   --seed <int>         Seed the PRNG (deterministic dry-run); 0 = entropy
//   --simulate-escape    Dry-run helper: act as if Esc was pressed (no real keys)
//   --clear              Send Cmd+A then Backspace first.
//   --return             Send Return after typing.
//   --physical           Real ANSI key codes for ASCII (correct `event.code`).
//   --keep-input-source  Do not temporarily switch to an ASCII keyboard layout.
//   --check              Exit 0 if Accessibility is granted, 1 otherwise.
//   --prompt             Show the macOS Accessibility prompt if not granted.
//   --dry-run            Build the sequence, post nothing, print DRYRUN + TRACE.

import Foundation
import Darwin
import CoreGraphics
import ApplicationServices
import Carbon

// MARK: - Options

struct HumanConfig {
    var wpmMin = 75
    var wpmMax = 100
    var longWordLength = 10
    var pauseChance = 50
    var pauseMinMs = 500
    var pauseMaxMs = 3_000
    var phraseMin = 10
    var phraseMax = 20
    var phrasePauseMs = 1_000
    var typoChance = 5
}

struct Options {
    var focusDelayMs = 700
    var intervalMs = 12
    var jitterMs = 0
    var clearFirst = false
    var pressReturn = false
    var physicalKeys = false
    var keepInputSource = false
    var checkOnly = false
    var promptPermission = false
    var dryRun = false
    var simulateEscape = false
    var humanMode = false
    var human = HumanConfig()
    var seed: UInt64 = 0
}

func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
    min(max(value, lower), upper)
}

let numericFlags: Set<String> = [
    "--focus-delay", "--interval", "--jitter",
    "--wpm-min", "--wpm-max", "--long-word", "--pause-chance",
    "--pause-min", "--pause-max", "--phrase-min", "--phrase-max",
    "--phrase-pause", "--typo-chance", "--seed",
]

func applyNumber(_ flag: String, _ value: Int, to options: inout Options) {
    switch flag {
    case "--focus-delay": options.focusDelayMs = clamp(value, 0, 30_000)
    case "--interval": options.intervalMs = clamp(value, 0, 2_000)
    case "--jitter": options.jitterMs = clamp(value, 0, 2_000)
    case "--wpm-min": options.human.wpmMin = clamp(value, 1, 600)
    case "--wpm-max": options.human.wpmMax = clamp(value, 1, 600)
    case "--long-word": options.human.longWordLength = clamp(value, 0, 500)
    case "--pause-chance": options.human.pauseChance = clamp(value, 0, 100)
    case "--pause-min": options.human.pauseMinMs = clamp(value, 0, 600_000)
    case "--pause-max": options.human.pauseMaxMs = clamp(value, 0, 600_000)
    case "--phrase-min": options.human.phraseMin = clamp(value, 1, 10_000)
    case "--phrase-max": options.human.phraseMax = clamp(value, 1, 10_000)
    case "--phrase-pause": options.human.phrasePauseMs = clamp(value, 0, 600_000)
    case "--typo-chance": options.human.typoChance = clamp(value, 0, 100)
    case "--seed": options.seed = UInt64(max(value, 0))
    default: break
    }
}

func parseOptions() -> Options {
    var options = Options()
    let arguments = CommandLine.arguments
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if numericFlags.contains(argument) {
            if index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
                applyNumber(argument, value, to: &options)
            }
            index += 2
            continue
        }
        switch argument {
        case "--clear": options.clearFirst = true
        case "--return": options.pressReturn = true
        case "--physical": options.physicalKeys = true
        case "--keep-input-source": options.keepInputSource = true
        case "--check": options.checkOnly = true
        case "--prompt": options.promptPermission = true
        case "--dry-run": options.dryRun = true
        case "--simulate-escape": options.simulateEscape = true
        case "--human": options.humanMode = true
        default:
            FileHandle.standardError.write(Data("Unknown option: \(argument)\n".utf8))
        }
        index += 1
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - Accessibility

func accessibilityTrusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

// MARK: - Esc abort

enum TypingInterrupt: Error {
    case escape
}

/// Watches for Esc via a listen-only CGEventTap. Empirical check on this macOS:
/// CGEventSource.keyState does NOT report ordinary Esc key-down events, so
/// polling that API alone would miss real key presses. A listen-only tap needs
/// only the Accessibility permission the helper already requires.
final class EscapeMonitor {
    private let lock = NSLock()
    private var triggered = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var backgroundLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private let simulated: Bool

    init(simulated: Bool = false) {
        self.simulated = simulated
    }

    private func mark() {
        lock.lock()
        triggered = true
        lock.unlock()
    }

    /// Returns false if the tap could not be created; typing still works, but
    /// Esc aborts will be unavailable (the caller reports a degraded state).
    func start() -> Bool {
        if simulated { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: CGEventTapOptions(rawValue: 1)!, // kCGEventTapOptionListenOnly
            eventsOfInterest: mask,
            callback: { _, _, event, info in
                // kVK_Escape == 53. We never post Esc ourselves, so our own
                // synthetic typing cannot trigger a false positive.
                if event.getIntegerValueField(.keyboardEventKeycode) == 53, let info {
                    Unmanaged<EscapeMonitor>.fromOpaque(info).takeUnretainedValue().mark()
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else { return false }

        tap = created
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        else { return false }
        source = runLoopSource

        DispatchQueue.global(qos: .userInteractive).async {
            let loop = CFRunLoopGetCurrent()
            self.lock.lock()
            self.backgroundLoop = loop
            self.lock.unlock()
            CFRunLoopAddSource(loop, runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            self.ready.signal()
            CFRunLoopRun()
        }
        return ready.wait(timeout: .now() + 1.0) == .success
    }

    func check() -> Bool {
        if simulated { return true }
        lock.lock()
        let hit = triggered
        lock.unlock()
        return hit
    }

    func stop() {
        lock.lock()
        let loop = backgroundLoop
        lock.unlock()
        if let source, let loop { CFRunLoopRemoveSource(loop, source, .commonModes) }
        if let loop { CFRunLoopStop(loop) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}

/// Sleeps in 10 ms slices so an Esc press can interrupt even a multi-second pause.
func waitWithAbort(_ milliseconds: Double, monitor: EscapeMonitor?, dryRun: Bool) throws {
    if monitor?.check() == true { throw TypingInterrupt.escape }
    if dryRun || milliseconds <= 0 { return }
    let deadline = Date().addingTimeInterval(milliseconds / 1_000.0)
    while true {
        if monitor?.check() == true { throw TypingInterrupt.escape }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { break }
        Thread.sleep(forTimeInterval: min(0.01, remaining))
    }
}

// MARK: - Input source (best effort)

func cfString(_ value: CFString?) -> String? {
    guard let value = value else { return nil }
    return value as String
}

func currentInputSource() -> TISInputSource? {
    TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
}

func selectASCIIInputSource() -> TISInputSource? {
    let preferredIDs = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
    let properties = [
        cfString(kTISPropertyInputSourceType)!: cfString(kTISTypeKeyboardLayout)!,
    ] as CFDictionary
    guard let cfList = TISCreateInputSourceList(properties, false)?.takeRetainedValue(),
          let list = cfList as? [TISInputSource]
    else { return nil }

    for wanted in preferredIDs {
        for source in list {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            else { continue }
            let identifier = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
            if identifier == wanted {
                return TISSelectInputSource(source) == noErr ? source : nil
            }
        }
    }
    return nil
}

// MARK: - ANSI key-code map

let ansiLayout: [UInt16: (Character, Character)] = [
    0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 4: ("h", "H"),
    5: ("g", "G"), 6: ("z", "Z"), 7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"),
    11: ("b", "B"), 12: ("q", "Q"), 13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"),
    16: ("y", "Y"), 17: ("t", "T"),
    18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"), 22: ("6", "^"),
    23: ("5", "%"), 24: ("=", "+"), 25: ("9", "("), 26: ("7", "&"), 27: ("-", "_"),
    28: ("8", "*"), 29: ("0", ")"), 30: ("]", "}"), 31: ("o", "O"), 32: ("u", "U"),
    33: ("[", "{"), 34: ("i", "I"), 35: ("p", "P"), 37: ("l", "L"), 38: ("j", "J"),
    39: ("'", "\""), 40: ("k", "K"), 41: (";", ":"), 42: ("\\", "|"),
    43: (",", "<"), 44: ("/", "?"), 45: ("n", "N"), 46: ("m", "M"),
    47: (".", ">"), 49: (" ", " "), 50: ("`", "~"),
]

func buildReverseMap() -> [UInt16: (CGKeyCode, Bool)] {
    var map: [UInt16: (CGKeyCode, Bool)] = [:]
    for (code, pair) in ansiLayout {
        if let unit = String(pair.0).utf16.first { map[unit] = (CGKeyCode(code), false) }
        if pair.1 != pair.0, let unit = String(pair.1).utf16.first {
            map[unit] = (CGKeyCode(code), true)
        }
    }
    return map
}

// MARK: - Seeded PRNG (xorshift64*)

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        if seed != 0 {
            state = seed
        } else {
            var mixed = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            mixed ^= UInt64(ProcessInfo.processInfo.processIdentifier) << 32
            mixed ^= UInt64(arc4random()) << 8
            state = mixed == 0 ? 0x9E37_79B9_7F4A_7C15 : mixed
        }
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    mutating func int(_ upperExclusive: Int) -> Int {
        guard upperExclusive > 0 else { return 0 }
        return Int(next() % UInt64(upperExclusive))
    }

    mutating func range(_ lower: Int, _ upper: Int) -> Int {
        upper <= lower ? lower : lower + int(upper - lower + 1)
    }

    mutating func unit() -> Double {
        Double(next() % 1_000_000) / 1_000_000.0
    }

    mutating func chance(_ percent: Int) -> Bool {
        int(100) < clamp(percent, 0, 100)
    }
}

// MARK: - QWERTY neighbours for realistic typos

let neighbourStrings: [String: String] = [
    "q": "wa", "w": "qesa", "e": "wrsd", "r": "etfd", "t": "rygf", "y": "tuhg",
    "u": "yijh", "i": "uokj", "o": "iplk", "p": "ol",
    "a": "qwsz", "s": "awedxz", "d": "serfcx", "f": "drtgvc", "g": "ftyhbv",
    "h": "gyujnb", "j": "huikmn", "k": "jiolm", "l": "kop",
    "z": "asx", "x": "zsdc", "c": "xdfv", "v": "cfgb", "b": "vghn",
    "n": "bhjm", "m": "njkl",
]

let neighbourCodes: [UInt16: [UInt16]] = Dictionary(
    uniqueKeysWithValues: neighbourStrings.map { ($0.key.utf16.first!, Array($0.value.utf16)) }
)

func isASCIILetter(_ unit: UInt16) -> Bool {
    (65...90).contains(unit) || (97...122).contains(unit)
}

/// Replaces one ASCII letter with a physically adjacent QWERTY key, preserving case.
func typoVariant(of word: [UniChar], rng: inout SeededRandom) -> [UniChar]? {
    let candidates = word.indices.filter { isASCIILetter(word[$0]) }
    guard !candidates.isEmpty else { return nil }
    let position = candidates[rng.int(candidates.count)]
    let original = word[position]
    let isUpper = (65...90).contains(original)
    let lowerCode: UInt16 = isUpper ? original + 32 : original
    guard let neighbours = neighbourCodes[lowerCode], !neighbours.isEmpty else { return nil }
    let picked = neighbours[rng.int(neighbours.count)]
    var result = word
    result[position] = isUpper ? picked - 32 : picked
    return result
}

func render(_ units: [UniChar]) -> String {
    String(utf16CodeUnits: units, count: units.count)
}

// MARK: - Segmentation

enum Segment {
    case word([UniChar])
    case literal([[UniChar]]) // each group is 1 UTF-16 unit or a surrogate pair
    case newLine
}

func isWordUnit(_ unit: UInt16) -> Bool {
    (48...57).contains(unit) || isASCIILetter(unit) || unit == 0x27 // digits, letters, apostrophe
}

func splitSegments(_ text: String) -> [Segment] {
    let units = Array(text.utf16)
    var segments: [Segment] = []
    var index = 0
    while index < units.count {
        let unit = units[index]
        if unit == 0x0A || unit == 0x0D {
            if unit == 0x0D, index + 1 < units.count, units[index + 1] == 0x0A {
                index += 1
            }
            segments.append(.newLine)
            index += 1
        } else if isWordUnit(unit) {
            var word: [UniChar] = []
            while index < units.count, isWordUnit(units[index]) {
                word.append(units[index])
                index += 1
            }
            segments.append(.word(word))
        } else {
            var groups: [[UniChar]] = []
            while index < units.count,
                  units[index] != 0x0A, units[index] != 0x0D,
                  !isWordUnit(units[index])
            {
                let current = units[index]
                if (0xD800...0xDBFF).contains(current),
                   index + 1 < units.count,
                   (0xDC00...0xDFFF).contains(units[index + 1])
                {
                    groups.append([current, units[index + 1]])
                    index += 2
                } else {
                    groups.append([current])
                    index += 1
                }
            }
            segments.append(.literal(groups))
        }
    }
    return segments
}

// MARK: - Event emitter

final class Emitter {
    private let source: CGEventSource?
    private let classicIntervalMs: Double
    private let classicJitterMs: Double
    private let physical: Bool
    private let dryRun: Bool
    private let human: HumanConfig?
    private let monitor: EscapeMonitor?
    private let reverseMap: [UInt16: (CGKeyCode, Bool)]
    private var rng: SeededRandom
    private var currentWpm: Double
    private var wordsSinceBreath = 0
    private var nextBreathAt: Int

    private(set) var transcript = ""
    private(set) var trace = ""
    private(set) var pauseCount = 0
    private(set) var pauseTotalMs = 0
    private(set) var breathCount = 0
    private(set) var typoCount = 0

    var currentWpmSnapshot: Double { currentWpm }

    init(options: Options, monitor: EscapeMonitor?) {
        dryRun = options.dryRun
        self.monitor = monitor
        source = dryRun ? nil : CGEventSource(stateID: .hidSystemState)
        classicIntervalMs = Double(options.intervalMs)
        classicJitterMs = Double(options.jitterMs)
        physical = options.physicalKeys
        human = options.humanMode ? options.human : nil
        reverseMap = buildReverseMap()
        rng = SeededRandom(seed: options.seed)
        currentWpm = Double(options.human.wpmMin + options.human.wpmMax) / 2.0
        nextBreathAt = rng.range(
            min(options.human.phraseMin, options.human.phraseMax),
            max(options.human.phraseMin, options.human.phraseMax)
        )
    }

    private func characterDelayMs() -> Double {
        guard human != nil else {
            let jitter = classicJitterMs > 0 ? Double(rng.range(0, Int(classicJitterMs))) : 0
            return classicIntervalMs + jitter
        }
        // Standard WPM: 5 characters (including spaces) == 1 word.
        let base = 60_000.0 / (5.0 * currentWpm)
        return base * (0.85 + 0.30 * rng.unit()) // +/- 15% drift inside a word
    }

    private func wait(_ milliseconds: Double) throws {
        try waitWithAbort(milliseconds, monitor: monitor, dryRun: dryRun)
    }

    private func removeLastUnit() {
        var units = Array(transcript.utf16)
        guard !units.isEmpty else { return }
        units.removeLast()
        transcript = String(utf16CodeUnits: units, count: units.count)
    }

    private static let holdUs: useconds_t = 2_000

    func key(_ code: CGKeyCode, flags: CGEventFlags = [], delay: Double? = nil, silent: Bool = false) throws {
        if dryRun {
            if code == 36 {
                transcript += "\n"
                if !silent { trace += "[RETURN]" }
            } else if code == 51 {
                removeLastUnit()
                if !silent { trace += "[BACKSPACE]" }
            } else if code == 0, flags.contains(.maskCommand), !silent {
                trace += "[SELECT_ALL]"
            }
        } else if let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        {
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            usleep(Emitter.holdUs)
            up.post(tap: .cghidEventTap)
        }
        try wait(delay ?? characterDelayMs())
    }

    func unicode(_ units: [UniChar], delay: Double? = nil) throws {
        if dryRun {
            transcript += render(units)
        } else if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        {
            down.flags = []
            up.flags = []
            let characters = units
            characters.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
            down.post(tap: .cghidEventTap)
            usleep(Emitter.holdUs)
            up.post(tap: .cghidEventTap)
        }
        try wait(delay ?? characterDelayMs())
    }

    private func emit(_ group: [UniChar]) throws {
        if physical, !dryRun, group.count == 1, let entry = reverseMap[group[0]] {
            try key(entry.0, flags: entry.1 ? .maskShift : [])
        } else {
            try unicode(group)
        }
    }

    func clearAll() throws {
        if dryRun {
            transcript = ""
            trace += "[SELECT_ALL+DELETE]"
            try wait(80)
            return
        }
        try key(CGKeyCode(0), flags: .maskCommand)
        try key(CGKeyCode(51), delay: 80)
    }

    private func backspace(_ count: Int) throws {
        guard count > 0 else { return }
        if dryRun { trace += "[BACKSPACE×\(count)]" }
        for _ in 0..<count {
            try key(CGKeyCode(51), delay: 60, silent: true)
        }
    }

    private func typeWord(_ word: [UniChar]) throws {
        guard let human else {
            for unit in word { try emit([unit]) }
            return
        }

        let low = min(human.wpmMin, human.wpmMax)
        let high = max(human.wpmMin, human.wpmMax)
        currentWpm = Double(rng.range(low, high))
        if dryRun { trace += "[WPM \(Int(currentWpm))]" }

        if word.count > human.longWordLength, rng.chance(human.pauseChance) {
            let pause = rng.range(
                min(human.pauseMinMs, human.pauseMaxMs),
                max(human.pauseMinMs, human.pauseMaxMs)
            )
            pauseCount += 1
            pauseTotalMs += pause
            if dryRun { trace += "[PAUSE \(pause)ms]" }
            try wait(Double(pause))
        }

        var emitted = word
        var needsCorrection = false
        if rng.chance(human.typoChance), let typo = typoVariant(of: word, rng: &rng) {
            emitted = typo
            needsCorrection = true
            typoCount += 1
            if dryRun { trace += "[TYPO \(render(word))->\(render(typo))]" }
        }

        for unit in emitted { try emit([unit]) }

        guard needsCorrection else { return }

        // A short "notice the mistake" beat before deleting makes the correction
        // look deliberate rather than like a macro.
        try wait(250 + 400 * rng.unit())

        try backspace(emitted.count)
        if dryRun { trace += "[RETYPE \(render(word))]" }
        for unit in word { try emit([unit]) }
    }

    /// Returns true when the last emitted event was a Return key.
    @discardableResult
    func type(_ text: String) throws -> Bool {
        var lastWasReturn = false
        for segment in splitSegments(text) {
            switch segment {
            case .newLine:
                try key(CGKeyCode(36))
                lastWasReturn = true
            case .literal(let groups):
                for group in groups { try emit(group) }
                lastWasReturn = false
            case .word(let word):
                try typeWord(word)
                lastWasReturn = false

                guard let human else { continue }
                wordsSinceBreath += 1
                if wordsSinceBreath >= nextBreathAt {
                    breathCount += 1
                    if dryRun { trace += "[PHRASE_PAUSE \(human.phrasePauseMs)ms]" }
                    try wait(Double(human.phrasePauseMs))
                    wordsSinceBreath = 0
                    nextBreathAt = rng.range(
                        min(human.phraseMin, human.phraseMax),
                        max(human.phraseMin, human.phraseMax)
                    )
                }
            }
        }
        return lastWasReturn
    }
}

// MARK: - Main

let options = parseOptions()

if options.checkOnly {
    let trusted = accessibilityTrusted(prompt: options.promptPermission)
    print(trusted ? "trusted" : "not-trusted")
    exit(trusted ? 0 : 1)
}

let raw = FileHandle.standardInput.readDataToEndOfFile()
guard let text = String(data: raw, encoding: .utf8), !text.isEmpty else {
    fail("EMPTY_INPUT: 没有可输入的文本。")
}

// Dry-run never posts an event and never sleeps, so it is safe for CI.
if options.dryRun {
    let monitor: EscapeMonitor? = options.simulateEscape ? EscapeMonitor(simulated: true) : nil
    let preview = Emitter(options: options, monitor: monitor)
    do {
        if options.clearFirst { try preview.clearAll() }
        let endsWithReturn = try preview.type(text)
        if options.pressReturn && !endsWithReturn { try preview.key(CGKeyCode(36)) }
        let escapedTranscript = preview.transcript.replacingOccurrences(of: "\n", with: "\\n")
        let escapedTrace = preview.trace.replacingOccurrences(of: "\n", with: "\\n")
        print("DRYRUN:\(escapedTranscript)")
        print("TRACE:\(escapedTrace)")
    } catch TypingInterrupt.escape {
        print("INTERRUPTED")
    }
    exit(0)
}

guard accessibilityTrusted(prompt: false) else {
    if accessibilityTrusted(prompt: true) {
        fail("ACCESSIBILITY_REQUIRED: 已弹出授权窗口，授权后请重新运行。")
    }
    fail("ACCESSIBILITY_REQUIRED: 请在「系统设置 → 隐私与安全性 → 辅助功能」中允许本程序。")
}

let monitor = EscapeMonitor()
if !monitor.start() {
    FileHandle.standardError.write(
        Data("ESC_TAP_UNAVAILABLE: 无法创建 Esc 监听，输入仍会继续但本次无法用 Esc 中断。\n".utf8)
    )
}
defer { monitor.stop() }

do {
    try waitWithAbort(Double(options.focusDelayMs), monitor: monitor, dryRun: false)

    // Input-source switching is best effort: never block typing because it failed.
    var previousInputSource: TISInputSource?
    var switchedInputSource = false
    if options.physicalKeys && !options.keepInputSource {
        previousInputSource = currentInputSource()
        if selectASCIIInputSource() != nil {
            switchedInputSource = true
            usleep(80_000)
        }
    }
    // This defer belongs to the `do` scope, so it also runs when Esc interrupts.
    defer {
        if switchedInputSource, let previous = previousInputSource {
            TISSelectInputSource(previous)
        }
    }

    let emitter = Emitter(options: options, monitor: monitor)
    if options.clearFirst { try emitter.clearAll() }
    let endedWithReturn = try emitter.type(text)
    if options.pressReturn && !endedWithReturn { try emitter.key(CGKeyCode(36)) }

    print(
        "TYPED \(text.utf16.count) utf16 units | wpm=\(Int(emitter.currentWpmSnapshot)) " +
            "| hesitations=\(emitter.pauseCount) (\(emitter.pauseTotalMs)ms) " +
            "| breaths=\(emitter.breathCount) | typos=\(emitter.typoCount)"
    )
} catch TypingInterrupt.escape {
    print("INTERRUPTED")
}
