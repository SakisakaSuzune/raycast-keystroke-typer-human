import {
  Alert,
  closeMainWindow,
  confirmAlert,
  environment,
  getPreferenceValues,
  showHUD,
  showToast,
  Toast,
} from "@raycast/api";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import path from "node:path";

const HELPER_NAME = "type-keystrokes-helper";
const HELPER_SOURCE = "TypeKeystrokes.swift";

export interface Preferences {
  humanMode: boolean;
  wpmMin: string;
  wpmMax: string;
  longWordLength: string;
  pauseChance: string;
  pauseMinMs: string;
  pauseMaxMs: string;
  phraseMin: string;
  phraseMax: string;
  phrasePauseMs: string;
  typoChance: string;
  focusDelay: string;
  interval: string;
  jitter: string;
  maxCharacters: string;
  physicalKeys: boolean;
  clearFirst: boolean;
  pressReturn: boolean;
}

export interface HumanOptions {
  humanMode?: boolean;
  wpmMin?: number;
  wpmMax?: number;
  longWordLength?: number;
  pauseChance?: number;
  pauseMinMs?: number;
  pauseMaxMs?: number;
  phraseMin?: number;
  phraseMax?: number;
  phrasePauseMs?: number;
  typoChance?: number;
}

export interface TypeOptions extends HumanOptions {
  focusDelay?: number;
  interval?: number;
  jitter?: number;
  physicalKeys?: boolean;
  clearFirst?: boolean;
  pressReturn?: boolean;
  maxCharacters?: number;
}

export type TyperErrorCode = "PERMISSION" | "INPUT" | "HELPER" | "SPAWN";

export class TyperError extends Error {
  constructor(
    message: string,
    readonly code: TyperErrorCode,
  ) {
    super(message);
    this.name = "TyperError";
  }
}

/** Fixed presets used only when human pacing is disabled. */
export const SPEED_PRESETS: Record<string, { interval: number; jitter: number }> = {
  instant: { interval: 0, jitter: 0 },
  fast: { interval: 5, jitter: 0 },
  normal: { interval: 12, jitter: 0 },
  slow: { interval: 40, jitter: 0 },
};

export function readNumber(value: string | undefined, fallback: number): number {
  if (value === undefined) return fallback;
  const parsed = Number.parseInt(value.trim(), 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

export function preferences(): Preferences {
  return getPreferenceValues<Preferences>();
}

export function clampPercent(value: number): number {
  return Math.min(Math.max(value, 0), 100);
}

export interface DurationEstimate {
  minMs: number;
  maxMs: number;
}

/** Distinguishes a completed run, a declined confirmation and an Esc interrupt. */
export interface TypeResult {
  characters: number;
  interrupted: boolean;
  cancelled: boolean;
  /** True when macOS refused the Esc event tap; typing still works. */
  escDegraded: boolean;
}

/**
 * Rough wall-clock estimate. WPM uses the standard definition (5 characters = 1
 * word), so per-character delay is 60000 / (5 * wpm) ms. Hesitations and typo
 * corrections are added as expected values over the detected ASCII words.
 */
export function estimateDuration(text: string, options: TypeOptions = {}): DurationEstimate {
  const p = preferences();
  const focusDelay = options.focusDelay ?? readNumber(p.focusDelay, 700);
  const human = options.humanMode ?? p.humanMode;

  if (!human) {
    const interval = options.interval ?? readNumber(p.interval, 12);
    const jitter = options.jitter ?? readNumber(p.jitter, 0);
    const ms = focusDelay + text.length * (interval + jitter / 2);
    return { minMs: Math.round(ms), maxMs: Math.round(ms) };
  }

  const wpmMin = Math.max(1, options.wpmMin ?? readNumber(p.wpmMin, 75));
  const wpmMax = Math.max(wpmMin, options.wpmMax ?? readNumber(p.wpmMax, 100));
  const fastPerChar = 60_000 / (5 * wpmMax);
  const slowPerChar = 60_000 / (5 * wpmMin);
  const meanPerChar = (fastPerChar + slowPerChar) / 2;

  const words = text.match(/[A-Za-z0-9']+/g) ?? [];
  const longThreshold = options.longWordLength ?? readNumber(p.longWordLength, 10);
  const longWords = words.filter((word) => word.length > longThreshold).length;

  const pauseChance = clampPercent(options.pauseChance ?? readNumber(p.pauseChance, 50)) / 100;
  const pauseMin = options.pauseMinMs ?? readNumber(p.pauseMinMs, 500);
  const pauseMax = options.pauseMaxMs ?? readNumber(p.pauseMaxMs, 3_000);
  const meanPause = (Math.min(pauseMin, pauseMax) + Math.max(pauseMin, pauseMax)) / 2;
  const expectedPause = longWords * pauseChance * meanPause;

  const phraseMin = Math.max(1, options.phraseMin ?? readNumber(p.phraseMin, 10));
  const phraseMax = Math.max(phraseMin, options.phraseMax ?? readNumber(p.phraseMax, 20));
  const phrasePauseMs = options.phrasePauseMs ?? readNumber(p.phrasePauseMs, 1_000);
  const expectedBreaths = words.length / ((phraseMin + phraseMax) / 2);
  const expectedPhrasePause = expectedBreaths * phrasePauseMs;

  const typoChance = clampPercent(options.typoChance ?? readNumber(p.typoChance, 5)) / 100;
  const meanWordLength = words.length ? words.reduce((sum, word) => sum + word.length, 0) / words.length : 0;
  // One typo costs: retyping the word + N Backspaces at 60ms + the notice beat.
  const expectedTypo = words.length * typoChance * (meanWordLength * meanPerChar + meanWordLength * 60 + 450);

  return {
    minMs: Math.round(focusDelay + text.length * fastPerChar + expectedPhrasePause + expectedTypo * 0.5),
    maxMs: Math.round(
      focusDelay + text.length * slowPerChar + expectedPhrasePause + expectedPause * 2 + expectedTypo * 1.5,
    ),
  };
}

export function formatDuration(ms: number): string {
  if (ms < 60_000) return `${Math.round(ms / 1_000)} 秒`;
  const minutes = ms / 60_000;
  return minutes < 60 ? `${minutes.toFixed(1)} 分钟` : `${(minutes / 60).toFixed(1)} 小时`;
}

// MARK: - Helper resolution

let cachedHelper: string | undefined;

/** Returns a runnable helper, rebuilding the shipped Swift source if the binary cannot run here. */
function resolveHelper(): string {
  if (cachedHelper && existsSync(cachedHelper)) return cachedHelper;

  const assets = environment.assetsPath;
  const bundled = path.join(assets, HELPER_NAME);
  let probeMessage = "";

  if (existsSync(bundled)) {
    try {
      chmodSync(bundled, 0o755);
    } catch {
      // Assets can live inside a read-only bundle; the file is usually already executable.
    }
    const probe = spawnSync(bundled, ["--check"], { encoding: "utf8", timeout: 10_000 });
    // `--check` exits 1 when Accessibility is missing, which still proves the binary runs.
    if (!probe.error && probe.status !== null) {
      cachedHelper = bundled;
      return bundled;
    }
    probeMessage = probe.error?.message ?? `exit=${String(probe.status)} signal=${String(probe.signal)}`;
  }

  const source = path.join(assets, HELPER_SOURCE);
  if (!existsSync(source)) {
    throw new TyperError(
      `找不到按键助手 ${bundled}。${probeMessage} 请在扩展目录执行 npm run build:helper。`,
      "HELPER",
    );
  }

  mkdirSync(environment.supportPath, { recursive: true });
  const output = path.join(environment.supportPath, HELPER_NAME);
  const build = spawnSync("swiftc", ["-O", "-o", output, source, "-framework", "Carbon"], {
    encoding: "utf8",
    timeout: 180_000,
  });
  if (build.error || build.status !== 0) {
    throw new TyperError(
      `按键助手与当前 CPU 架构不匹配，自动重编译失败：${build.error?.message ?? build.stderr?.trim() ?? "unknown"}`,
      "HELPER",
    );
  }
  chmodSync(output, 0o755);
  cachedHelper = output;
  return output;
}

interface HelperRun {
  code: number | null;
  stdout: string;
  stderr: string;
}

function execHelper(binary: string, args: string[], stdin = ""): Promise<HelperRun> {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => (stdout += chunk));
    child.stderr.on("data", (chunk: string) => (stderr += chunk));
    child.on("error", (error) => reject(new TyperError(`无法启动按键助手：${error.message}`, "SPAWN")));
    child.on("close", (code) => resolve({ code, stdout: stdout.trim(), stderr: stderr.trim() }));
    try {
      child.stdin.end(stdin, "utf8");
    } catch {
      // A spawn failure is already reported by the `error` event.
    }
  });
}

export async function checkAccessibility(prompt = false): Promise<{ trusted: boolean; helperPath: string }> {
  const helper = resolveHelper();
  const result = await execHelper(helper, prompt ? ["--check", "--prompt"] : ["--check"]);
  return { trusted: result.stdout === "trusted", helperPath: helper };
}

function helperFailure(result: HelperRun): TyperError {
  if (result.stderr.includes("ACCESSIBILITY_REQUIRED")) {
    return new TyperError(
      "缺少「辅助功能」权限。请运行「Check Accessibility Permission」命令完成授权后重试。",
      "PERMISSION",
    );
  }
  return new TyperError(result.stderr || `按键助手异常退出（code ${String(result.code)}）`, "HELPER");
}

/**
 * Hands focus back to the previous app, then injects text as real keyboard events.
 * Esc is handled natively by the helper and reported through `interrupted`.
 */
export async function typeText(text: string, options: TypeOptions = {}): Promise<TypeResult> {
  if (!text) throw new TyperError("没有可输入的文本。", "INPUT");

  const prefs = preferences();
  const limit = options.maxCharacters ?? readNumber(prefs.maxCharacters, 2_000);
  if (text.length > limit) {
    throw new TyperError(
      `文本共 ${text.length} 个字符，超过安全上限 ${limit}。可在扩展偏好中调整 Max Characters。`,
      "INPUT",
    );
  }

  const helper = resolveHelper();

  // No permission pre-check on purpose: macOS may attribute a child process
  // differently for AXIsProcessTrusted than for CGEvent posting. The helper is
  // the single authoritative judge.
  const focusDelay = options.focusDelay ?? readNumber(prefs.focusDelay, 700);
  const interval = options.interval ?? readNumber(prefs.interval, 12);
  const jitter = options.jitter ?? readNumber(prefs.jitter, 0);
  const physicalKeys = options.physicalKeys ?? prefs.physicalKeys;
  const clearFirst = options.clearFirst ?? prefs.clearFirst;
  const pressReturn = options.pressReturn ?? prefs.pressReturn;
  const humanMode = options.humanMode ?? prefs.humanMode;

  const args = [
    "--focus-delay",
    String(Math.min(focusDelay, 30_000)),
    "--interval",
    String(Math.min(interval, 2_000)),
    "--jitter",
    String(Math.min(jitter, 2_000)),
  ];

  if (humanMode) {
    const wpmMin = Math.max(1, options.wpmMin ?? readNumber(prefs.wpmMin, 75));
    const wpmMax = Math.max(wpmMin, options.wpmMax ?? readNumber(prefs.wpmMax, 100));
    const pauseMin = options.pauseMinMs ?? readNumber(prefs.pauseMinMs, 500);
    const pauseMax = options.pauseMaxMs ?? readNumber(prefs.pauseMaxMs, 3_000);
    const phraseMin = Math.max(1, options.phraseMin ?? readNumber(prefs.phraseMin, 10));
    const phraseMax = Math.max(phraseMin, options.phraseMax ?? readNumber(prefs.phraseMax, 20));
    const phrasePauseMs = options.phrasePauseMs ?? readNumber(prefs.phrasePauseMs, 1_000);
    args.push(
      "--human",
      "--wpm-min",
      String(Math.min(wpmMin, 600)),
      "--wpm-max",
      String(Math.min(wpmMax, 600)),
      "--long-word",
      String(Math.min(options.longWordLength ?? readNumber(prefs.longWordLength, 10), 500)),
      "--pause-chance",
      String(clampPercent(options.pauseChance ?? readNumber(prefs.pauseChance, 50))),
      "--pause-min",
      String(Math.min(Math.min(pauseMin, pauseMax), 600_000)),
      "--pause-max",
      String(Math.min(Math.max(pauseMin, pauseMax), 600_000)),
      "--phrase-min",
      String(Math.min(phraseMin, 10_000)),
      "--phrase-max",
      String(Math.min(phraseMax, 10_000)),
      "--phrase-pause",
      String(Math.min(Math.max(phrasePauseMs, 0), 600_000)),
      "--typo-chance",
      String(clampPercent(options.typoChance ?? readNumber(prefs.typoChance, 5))),
    );
  }

  if (physicalKeys) args.push("--physical");
  if (clearFirst) args.push("--clear");
  if (pressReturn) args.push("--return");

  // Human pacing can occupy the keyboard for many minutes. This guard lives here
  // so both the form command and the no-view clipboard command are covered.
  const estimate = estimateDuration(text, options);
  if (estimate.maxMs > 8 * 60_000) {
    const proceed = await confirmAlert({
      title: "预计耗时较长",
      message: `按当前设置，${text.length} 个字符预计需要 ${formatDuration(estimate.minMs)} ～ ${formatDuration(
        estimate.maxMs,
      )}。期间键盘会被占用，且 Raycast 窗口已关闭。确认继续？`,
      primaryAction: { title: "继续输入", style: Alert.ActionStyle.Default },
      dismissAction: { title: "取消" },
    });
    if (!proceed) return { characters: 0, interrupted: false, cancelled: true, escDegraded: false };
  }

  // Raycast is frontmost while a command runs. Closing its window activates the
  // app that was behind it, so the caret stays in the intended input field.
  await closeMainWindow({ clearRootSearch: true });

  const result = await execHelper(helper, args, text);
  if (result.code !== 0) throw helperFailure(result);
  const interrupted = result.stdout.startsWith("INTERRUPTED");
  return {
    characters: interrupted ? 0 : text.length,
    interrupted,
    cancelled: false,
    escDegraded: result.stderr.includes("ESC_TAP_UNAVAILABLE"),
  };
}

/** Returns undefined when the run was cancelled (no HUD needed). */
export function resultMessage(result: TypeResult): string | undefined {
  if (result.cancelled) return undefined;
  if (result.interrupted) return "已按 Esc 中断输入";
  return `已模拟输入 ${result.characters} 个字符${result.escDegraded ? "（Esc 监听不可用）" : ""}`;
}

export async function reportError(error: unknown, fallbackTitle = "输入失败"): Promise<void> {
  const message = error instanceof Error ? error.message : String(error);
  await showToast({ style: Toast.Style.Failure, title: fallbackTitle, message });
  await showHUD(`${fallbackTitle}：${message}`);
}

export function helperLocation(): string {
  try {
    return resolveHelper();
  } catch {
    return path.join(environment.assetsPath, HELPER_NAME);
  }
}
