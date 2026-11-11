import { Action, ActionPanel, Clipboard, Form, showHUD, showToast, Toast } from "@raycast/api";
import { useState } from "react";
import {
  estimateDuration,
  formatDuration,
  preferences,
  readNumber,
  reportError,
  resultMessage,
  SPEED_PRESETS,
  typeText,
  type TypeOptions,
} from "./lib/typer";

interface Settings {
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
  speed: string;
  clearFirst: boolean;
  pressReturn: boolean;
  physicalKeys: boolean;
}

const prefs = preferences();

function initialSettings(): Settings {
  return {
    humanMode: prefs.humanMode,
    wpmMin: String(readNumber(prefs.wpmMin, 75)),
    wpmMax: String(readNumber(prefs.wpmMax, 100)),
    longWordLength: String(readNumber(prefs.longWordLength, 10)),
    pauseChance: String(readNumber(prefs.pauseChance, 50)),
    pauseMinMs: String(readNumber(prefs.pauseMinMs, 500)),
    pauseMaxMs: String(readNumber(prefs.pauseMaxMs, 3_000)),
    phraseMin: String(readNumber(prefs.phraseMin, 10)),
    phraseMax: String(readNumber(prefs.phraseMax, 20)),
    phrasePauseMs: String(readNumber(prefs.phrasePauseMs, 1_000)),
    typoChance: String(readNumber(prefs.typoChance, 5)),
    focusDelay: String(readNumber(prefs.focusDelay, 700)),
    speed: "normal",
    clearFirst: prefs.clearFirst,
    pressReturn: prefs.pressReturn,
    physicalKeys: prefs.physicalKeys,
  };
}

export default function Command() {
  const [text, setText] = useState("");
  const [textError, setTextError] = useState<string | undefined>();
  const [settings, setSettings] = useState<Settings>(initialSettings);

  function update<K extends keyof Settings>(key: K, value: Settings[K]) {
    setSettings((current) => ({ ...current, [key]: value }));
  }

  const preset = SPEED_PRESETS[settings.speed] ?? SPEED_PRESETS.normal;
  const typeOptions: TypeOptions = {
    focusDelay: readNumber(settings.focusDelay, 700),
    interval: preset.interval,
    jitter: preset.jitter,
    clearFirst: settings.clearFirst,
    pressReturn: settings.pressReturn,
    physicalKeys: settings.physicalKeys,
    humanMode: settings.humanMode,
    wpmMin: readNumber(settings.wpmMin, 75),
    wpmMax: readNumber(settings.wpmMax, 100),
    longWordLength: readNumber(settings.longWordLength, 10),
    pauseChance: readNumber(settings.pauseChance, 50),
    pauseMinMs: readNumber(settings.pauseMinMs, 500),
    pauseMaxMs: readNumber(settings.pauseMaxMs, 3_000),
    phraseMin: readNumber(settings.phraseMin, 10),
    phraseMax: readNumber(settings.phraseMax, 20),
    phrasePauseMs: readNumber(settings.phrasePauseMs, 1_000),
    typoChance: readNumber(settings.typoChance, 5),
  };

  const estimate = estimateDuration(text, typeOptions);
  const durationLabel = `${formatDuration(estimate.minMs)} ～ ${formatDuration(estimate.maxMs)}`;

  async function handleSubmit() {
    if (text.length === 0) {
      setTextError("请输入或粘贴要模拟输入的文字");
      return;
    }
    setTextError(undefined);

    try {
      const message = resultMessage(await typeText(text, typeOptions));
      if (message) await showHUD(message);
    } catch (error) {
      await reportError(error);
    }
  }

  async function fillFromClipboard() {
    const content = await Clipboard.readText();
    if (!content) {
      await showToast({ style: Toast.Style.Failure, title: "剪贴板为空或不含文本" });
      return;
    }
    setText(content);
    setTextError(undefined);
    await showToast({ style: Toast.Style.Success, title: "已填入剪贴板内容", message: `${content.length} 个字符` });
  }

  return (
    <Form
      enableDrafts
      actions={
        <ActionPanel>
          <Action.SubmitForm title="开始拟人输入" onSubmit={handleSubmit} />
          <Action title="从剪贴板填入" onAction={fillFromClipboard} />
          <Action title="清空文本" onAction={() => setText("")} />
        </ActionPanel>
      }
    >
      <Form.Description
        title="预计耗时"
        text={`${durationLabel}。默认 75–100 WPM；每 10–20 词与部分长词前会有停顿。请提前把光标放进目标输入框；输入过程中按 Esc 可随时中断。`}
      />
      <Form.TextArea
        id="text"
        title="要输入的文字"
        placeholder="在这里输入或粘贴文字（支持中文、emoji、换行）"
        value={text}
        onChange={(value) => {
          setText(value);
          if (value.length > 0) setTextError(undefined);
        }}
        error={textError}
        autoFocus
      />
      <Form.Checkbox
        id="humanMode"
        label="启用拟人节奏（WPM 漂移 / 长词停顿 / 打错重打）"
        value={settings.humanMode}
        onChange={(value) => update("humanMode", value)}
      />

      {settings.humanMode ? (
        <>
          <Form.Separator />
          <Form.Description
            title="节奏"
            text="标准 WPM 口径：5 个字符 = 1 单词。每个单词采样一次速度，词内再有 ±15% 漂移。"
          />
          <Form.TextField
            id="wpmMin"
            title="最低 WPM"
            value={settings.wpmMin}
            onChange={(value) => update("wpmMin", value)}
            info="75 WPM ≈ 每字符 160ms。"
          />
          <Form.TextField
            id="wpmMax"
            title="最高 WPM"
            value={settings.wpmMax}
            onChange={(value) => update("wpmMax", value)}
            info="100 WPM ≈ 每字符 120ms。"
          />
          <Form.Separator />
          <Form.Description title="长词犹豫" text="仅对连续的 ASCII 字母/数字串生效，中文按单字处理不会触发。" />
          <Form.TextField
            id="longWordLength"
            title="长词阈值（严格大于）"
            value={settings.longWordLength}
            onChange={(value) => update("longWordLength", value)}
          />
          <Form.TextField
            id="pauseChance"
            title="停顿概率 (%)"
            value={settings.pauseChance}
            onChange={(value) => update("pauseChance", value)}
          />
          <Form.TextField
            id="pauseMinMs"
            title="停顿下限 (ms)"
            value={settings.pauseMinMs}
            onChange={(value) => update("pauseMinMs", value)}
          />
          <Form.TextField
            id="pauseMaxMs"
            title="停顿上限 (ms)"
            value={settings.pauseMaxMs}
            onChange={(value) => update("pauseMaxMs", value)}
          />
          <Form.Separator />
          <Form.Description title="短语停顿" text="每输入 10–20 个单词（每轮随机）后固定停顿 1 秒，模拟换气的节奏。" />
          <Form.TextField
            id="phraseMin"
            title="间隔词数下限"
            value={settings.phraseMin}
            onChange={(value) => update("phraseMin", value)}
          />
          <Form.TextField
            id="phraseMax"
            title="间隔词数上限"
            value={settings.phraseMax}
            onChange={(value) => update("phraseMax", value)}
          />
          <Form.TextField
            id="phrasePauseMs"
            title="停顿时长 (ms)"
            value={settings.phrasePauseMs}
            onChange={(value) => update("phrasePauseMs", value)}
          />
          <Form.Separator />
          <Form.Description
            title="错字与纠正"
            text="按 QWERTY 邻键替换一个字母；整词打完后逐字删除并重新输入正确版本。"
          />
          <Form.TextField
            id="typoChance"
            title="错字概率 (% / 每词)"
            value={settings.typoChance}
            onChange={(value) => update("typoChance", value)}
          />
        </>
      ) : (
        <Form.Dropdown
          id="speed"
          title="输入速度（经典模式）"
          value={settings.speed}
          onChange={(value) => update("speed", value)}
        >
          <Form.Dropdown.Item value="instant" title="极快 · 0ms" />
          <Form.Dropdown.Item value="fast" title="快 · 5ms" />
          <Form.Dropdown.Item value="normal" title="正常 · 12ms" />
          <Form.Dropdown.Item value="slow" title="慢 · 40ms" />
        </Form.Dropdown>
      )}

      <Form.Separator />
      <Form.TextField
        id="focusDelay"
        title="焦点延迟 (ms)"
        value={settings.focusDelay}
        onChange={(value) => update("focusDelay", value)}
        info="关闭 Raycast 窗口后等待多久再开始输入。若字符打进 Raycast 或丢失，请调大。"
      />
      <Form.Checkbox
        id="clearFirst"
        label="先清空目标输入框（⌘A + 删除）"
        value={settings.clearFirst}
        onChange={(value) => update("clearFirst", value)}
      />
      <Form.Checkbox
        id="pressReturn"
        label="输入完成后按回车"
        value={settings.pressReturn}
        onChange={(value) => update("pressReturn", value)}
      />
      <Form.Checkbox
        id="physicalKeys"
        label="ASCII 使用物理键码"
        value={settings.physicalKeys}
        onChange={(value) => update("physicalKeys", value)}
      />
    </Form>
  );
}
