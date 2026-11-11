import { Clipboard, showHUD } from "@raycast/api";
import { reportError, resultMessage, typeText } from "./lib/typer";

/** No-view command: type the clipboard content using the extension preferences. */
export default async function Command() {
  const content = await Clipboard.readText();
  if (!content) {
    await showHUD("剪贴板为空，没有可输入的文字");
    return;
  }

  try {
    const message = resultMessage(await typeText(content));
    if (message) await showHUD(message);
  } catch (error) {
    await reportError(error);
  }
}
