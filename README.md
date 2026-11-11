# Keystroke Typer · Human（拟人节奏 fork）

从 `~/Documents/GitHub/raycast-keystroke-typer` 派生的**独立扩展**。原版完全保留、未修改；本 fork 使用独立的扩展名 `keystroke-typer-human`、独立图标与独立注册目录，两者可同时启用。

基础能力不变：把文字（含中文、emoji、换行）注入为 OS 级 `CGEvent` 键盘事件，不写剪贴板、不触发 `paste`，因此可填入屏蔽粘贴的输入框。

> 适用范围同原版：解决的是**禁止粘贴 / `onpaste` 检测**，不是把受保护页面里的文字复制出来。请遵守目标站点条款，勿用于侵犯版权内容或规避考试 / 测评的反作弊规则。

---

## 当前行为

### 1. 75–100 WPM 浮动节奏

| 口径 | 实现 |
| --- | --- |
| WPM 定义 | 标准口径：**5 个字符 = 1 word**（含空格）。每字符间隔 `60000 / (5 × wpm)` ms |
| 默认区间 | 75 WPM ≈ 160 ms/字符；100 WPM ≈ 120 ms/字符 |
| 采样粒度 | **每个单词开始时**采样一次 WPM，词内叠加 ±15% 漂移；空格/标点沿用当前速度 |
| "单词"定义 | 连续的 ASCII 字母 / 数字 / `'` 序列（`[A-Za-z0-9']+`）。中文按单字处理，不参与长词判定；emoji 代理对不会被拆坏 |

### 2. Esc 中断

- 助手启动一个 **listen-only `CGEventTap`** 监听 `kVK_Escape`（keycode 53），所有等待被切成 10 ms 片段轮询该标志，因此**长词停顿、短语停顿、字符间隔、焦点延迟期间都能立即中断**（响应 ≤10 ms）。
- 中断时输出 `INTERRUPTED`、恢复临时切换的输入法、停止 tap 并退出；Raycast 侧给出中性 HUD「已按 Esc 中断输入」，不按失败处理。
- 选择事件 tap 的原因：实测 `CGEventSource.keyState` **不会**反映普通 Esc 的 keyDown，单靠状态轮询会漏掉按键。listen-only tap 只需助手本来就要的「辅助功能」权限，不需要额外的「输入监控」权限。
- **副作用**：listen-only tap 不会吞掉事件，Esc 仍会传给当前前台应用（浏览器可能同时关闭弹窗）。若系统拒绝创建 tap，助手仍可正常打字，但 HUD 会标注「Esc 监听不可用」。

### 3. 每 10–20 个词停顿 1 秒

- 每完成一个单词后计数；达到本轮随机阈值（10–20 中均匀取值）时停顿 **1000 ms**，随后重置计数并重新抽取阈值。
- 停顿发生在**词与词之间**，不会插入单词内部；TRACE 里记为 `[PHRASE_PAUSE 1000ms]`。
- 三个参数（词数下限 / 上限 / 停顿时长）均可在偏好与表单中调整。

### 4. 长词停顿 0.5–3 秒

- 长度**严格大于**阈值（默认 10）的单词，在其第一个字符**之前**以 50% 概率停顿 500–3000 ms（区间内均匀随机）。
- 停顿使用可中断的分片睡眠，不再受 `usleep` 的 UInt32 微秒上限限制。

### 5. 打错字 → 整词删除 → 重打（保留）

- 每个单词独立 5% 概率；随机挑一个 ASCII 字母替换成 **QWERTY 物理邻键**（保持大小写），例如 `remarkably → rsmarkably`。
- 整词打完 → 250–650 ms「察觉」停顿 → 发送 N 次 Backspace（N = 该词字符数，60 ms/次）→ 重打正确词。重打不再触发错字，最终文本始终等于输入。

---

## 可配置项（偏好 + 表单）

| 项 | 默认 | 说明 |
| --- | --- | --- |
| Human Pacing | 开 | 关闭后回退原版固定间隔引擎（含速度下拉） |
| Minimum / Maximum WPM | **75 / 100** | 每词速度采样区间 |
| Long Word Threshold | 10 | 严格大于该长度才算长词 |
| Hesitation Chance | 50% | 长词前停顿概率 |
| Hesitation Min / Max | **500 / 3000 ms** | 长词停顿区间 |
| Words Between Breaths Min / Max | **10 / 20** | 每轮短语停顿的词数阈值 |
| Breath Pause | **1000 ms** | 短语停顿固定时长 |
| Typo Chance | 5% | 每词出错概率 |
| Focus Delay | 700 ms | 关闭 Raycast 窗口后等待焦点归还 |
| Max Characters | **2000** | 安全上限（速度提升后由 500 上调） |
| interval / jitter | 12 / 0 ms | 仅经典模式生效 |
| physicalKeys / clearFirst / pressReturn | 关 | 同原版 |

表单顶部动态显示**预计耗时区间**（WPM 区间 + 长词停顿 + 短语停顿 + 错字期望值）。预计上限超过 8 分钟时，两条输入命令都会弹确认框（守卫在共用层，无界面命令同样受保护）。

### 耗时量级

| 文本长度 | 大致耗时（含停顿） |
| --- | --- |
| 500 字符 | 约 1.5–2 分钟 |
| 2000 字符（默认上限） | 约 4–6 分钟 |

适合短文本、演示与趣味场景；长文仍会长时间占用键盘。

---

## 三个命令

| 命令 | 模式 | 用途 |
| --- | --- | --- |
| **Type Text Like a Human** | view | 表单输入文字，实时调所有参数、查看预计耗时 |
| **Type Clipboard Like a Human** | no-view | 按偏好一键输入剪贴板内容，适合绑快捷键 |
| **Check Accessibility Permission** | no-view | 检查 / 申请辅助功能权限 |

使用前**先把光标点进目标输入框**。提交后 Raycast 窗口关闭、焦点交还之前的应用，延迟后开始逐字输入；过程中按 **Esc** 可随时中断。

---

## 安装与启用

已构建并注册到 `~/.config/raycast/extensions/keystroke-typer-human/`。在 Raycast 里执行 **Reload Extensions** 或重启 Raycast，搜索 `Type Text Like a Human`。若未出现，在项目目录执行 `npm run dev`，或用 Extensions → Import Extension 指向 `dist/`。

首次使用先运行 **Check Accessibility Permission**，在「系统设置 → 隐私与安全性 → 辅助功能」授权（通常是 Raycast）。该权限同时供事件 tap 使用。授权后如仍失败，重启一次 Raycast。

---

## 自检与可复现随机

`--dry-run` 只构造事件序列并打印，**不发送按键、不 sleep**。输出两行：

```
DRYRUN:<最终屏幕文本，\n 转义>
TRACE:<[WPM n] [PAUSE nms] [PHRASE_PAUSE nms] [TYPO a->b] [BACKSPACE×N] [RETYPE word] ...>
```

`--seed <n>` 播种 xorshift64* PRNG，使 WPM、停顿、错字完全可复现。`--simulate-escape` 让 dry-run 走完整中断路径而不碰真实按键。

```bash
printf 'The internationalization effort was unexpectedly complicated, but overall the documentation remained remarkably comprehensive.' \
  | ./assets/type-keystrokes-helper --dry-run --human --seed 7
```

`npm run test:helper` 共 **31 项断言**，覆盖：

- 经典引擎回归：中文 / emoji / CRLF / Tab / 清空 / 回车 / 物理键码；
- 新默认：WPM 全部落在 [75,100]、长词停顿落在 500–3000 ms、短语停顿恒为 1000 ms；
- 每 10 词一轮时，30 个词恰好产生 3 次短语停顿；WPM / 停顿 / 短语时长参数透传；
- 错字与 `BACKSPACE×N` / `RETYPE`、最终文本与输入一致、同种子可复现、概率开关、中文不被改写；
- Esc 在拟人 / 经典 / 清空前三种场景均中断，未模拟时正常输出。

**真实 Esc 端到端验证**：用临时「吞事件 tap」保护前台应用后，向真实运行的助手投递一次 Esc，助手输出 `INTERRUPTED` 并退出；该验证对项目内二进制与 Raycast 注册目录内的二进制都执行过。

---

## 与原版的关系 / 验证结果

| 项目 | 状态 |
| --- | --- |
| 原项目 `~/Documents/GitHub/raycast-keystroke-typer` | 未改动 |
| 原注册目录 `~/.config/raycast/extensions/keystroke-typer` | 校验和前后一致 |
| fork 注册目录 | `~/.config/raycast/extensions/keystroke-typer-human`（独立） |
| `npm run build` / `npx ray build -e dist -o dist` | 通过 |
| `npx tsc --noEmit` / `npm run lint:local` | 通过 |
| `npm run test:helper` | 31/31 通过 |
| 真实 Esc 中断（项目内 + 注册版） | 通过 |

`npm run lint`（完整版）会联网校验 `author` 是否为 Raycast 商店账号；本地开发用 `lint:local`，发布前把 `package.json` 的 `author` 改成你自己的 Raycast 用户名。

---

## 限制与注意事项

- **Esc 会同时到达前台应用**（listen-only tap 不吞事件）；若当前应用对 Esc 敏感，可能有额外界面反应。
- **密码框 / 安全键盘输入**：macOS 会拒绝合成事件，这是系统安全设计。
- **换行 = 回车**：`\n` 转成 Return 键；单行输入框可能直接提交表单。
- **删除键依赖光标位置**：错字纠正依赖 Backspace 逐字删除刚打出的词。目标页面若有自动补全 / 实时格式化 / 输入掩码，建议降低错字概率或关闭。
- **长任务**：打字期间键盘被占用；中途切换窗口会让后续字符打进错误位置。除按 Esc 外，也可终止 `type-keystrokes-helper` 进程。
- **极少数自绘控件**可能忽略带 Unicode 字符串的 CGEvent，可开启「ASCII 使用物理键码」。
- **架构**：自带 arm64 二进制；换架构执行 `npm run build:helper`，扩展也会用随包 `TypeKeystrokes.swift` 自动重编译。

---

## 目录与命令

```
raycast-keystroke-typer-human/
├── src/{type-text.tsx, type-clipboard.ts, check-accessibility.ts, lib/typer.ts}
├── assets/{TypeKeystrokes.swift, type-keystrokes-helper, icon.png}
├── scripts/{build-helper.sh, test-helper.sh}
├── dist/                    已构建、可直接导入
└── README.md
```

```bash
npm run dev            # 开发模式注册（热重载）
npm run build          # 构建并写入 Raycast 本地扩展目录
npm run lint:local     # ESLint + Prettier
npm run typecheck      # TypeScript 检查
npm run build:helper   # 重新编译 Swift 助手
npm run test:helper    # 31 项 dry-run 自检
```
