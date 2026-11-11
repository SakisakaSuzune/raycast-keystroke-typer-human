import { Alert, confirmAlert, showToast, Toast } from "@raycast/api";
import { checkAccessibility, helperLocation, reportError } from "./lib/typer";

/** One-time setup command: verify / request the Accessibility permission. */
export default async function Command() {
  const helper = helperLocation();

  try {
    const status = await checkAccessibility(false);
    if (status.trusted) {
      await showToast({
        style: Toast.Style.Success,
        title: "辅助功能已授权",
        message: "现在可以把文字模拟输入到任意输入框了",
      });
      return;
    }

    const confirmed = await confirmAlert({
      title: "需要「辅助功能」权限",
      message:
        "macOS 要求合成键盘事件的进程拥有辅助功能权限。确认后会弹出系统授权窗口，请在其中开启权限（可能需要重启 Raycast 才生效）。\n\n" +
        `若授权列表中没有出现该条目，请手动把下面的文件拖入列表：\n${helper}`,
      primaryAction: { title: "打开系统授权", style: Alert.ActionStyle.Default },
      dismissAction: { title: "取消" },
    });
    if (!confirmed) return;

    await checkAccessibility(true);
    await showToast({
      style: Toast.Style.Animated,
      title: "已请求授权",
      message: "完成系统设置中的授权后，重新运行本命令确认",
    });
  } catch (error) {
    await reportError(error, "权限检查失败");
  }
}
