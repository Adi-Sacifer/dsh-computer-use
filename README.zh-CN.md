# cu-windows —— 给 AI agent 一双真的眼睛和一双手

一个**单文件 PowerShell 工具包**，让 AI agent 真正操作 Windows 桌面：截屏、找到控件、点击、输入，
并且**验证到底点没点中**。不需要 Python、不需要 Node、不需要装任何东西——Windows 自带的
PowerShell 5.1 就够。

```
scripts/cu.ps1    ~1200 行，纯 ASCII 源码，兼容 PowerShell 5.1
```

**[English README](README.md)**

---

## 为什么还要再写一个

大多数桌面自动化脚本都死在同一个地方：点下去，什么都没发生，而**无论 agent 还是人都无法判断**
是坐标错了、窗口动了，还是那个控件根本不接受合成输入。这个工具包是连续几天在真机上边用边修出来的，
每一条失败都追到了根因。其中有两条，我没见过被广泛写下来：

### 一、Chromium / Electron 应用默认没有无障碍树——必须先唤醒

Chrome/Edge 里的任何网页、VS Code、Slack、Discord，以及所有 Electron 桌面应用，
**默认把无障碍引擎关着**，直到有东西向它索取无障碍对象。在那之前，UI Automation 查出来几乎是空的，
于是 agent 只能退回去**目测被缩放的截图**——点击就这样落到隔壁按钮上了。

`cu.ps1` 会向目标窗口及其子窗口发送 `WM_GETOBJECT` / `OBJID_CLIENT`（这正是屏幕阅读器启动时做的事），
然后轮询等待树构建完成。实测一个普通 Electron 窗口：

| | 唤醒前 | 唤醒后 |
|---|---|---|
| UIA 节点 | 13 个（4 个有名，无可用矩形） | **158 个（140 个有名，每个都有真实矩形）** |

于是"从截图猜坐标"变成了 `uia -Mode find -Name "保存"`——直接打出控件的精确矩形**和该点的精确像素**。
在浏览器里这意味着真实的 DOM 元素：`Button | 开始游戏 | 1690,1290 462x141`。

### 二、把指针"送过去"的那个合成移动，本身可能就是毒药

一次点击不等于在你以为的位置发 `down`+`up`。实测：先用 `MOUSEEVENTF_MOVE` 把指针移过去再 `down`/`up`，
某些应用框架**会拒绝**；而指针由**物理鼠标**移到位之后，一模一样的 `down`/`up` 却被接受了。

所以 `cu.ps1` 用 `SetCursorPos`（真实光标移动）定位，**完全不发送任何合成移动事件**。

---

## 里面有什么

| | |
|---|---|
| **看** | 全屏 / 区域 / 单窗口截图；可叠加带标注的坐标网格，**每一条网格线都有编号** |
| **找** | UIA 树；按名字排序检索，返回精确矩形、是否在屏幕上、以及点击坐标；原生应用、Flutter（部分）、以及**唤醒后**的 Chromium/Electron/网页都可用 |
| **做** | 点击、双击、拖拽、滚轮、Unicode 安全输入（中文/emoji）、剪贴板粘贴、组合键、窗口聚焦/移动/显示 |
| **验** | 每次点击都回报**落点下方究竟是哪个窗口**；拒绝点击桌面外；`SendInput` 被拦（UIPI / 目标提权）时告警；反查该点实际属于另一个元素时告警 |
| **进度** | 一个极小的置顶活动指示器，实时显示 agent 在做什么——点击穿透、永不抢焦点，而且**对屏幕截图隐形** |
| **叠层** | 可选的"接管中"全屏特效，同样点击穿透、不抢焦点 |

## 环境要求

- Windows 10（19041+）或 Windows 11
- Windows PowerShell 5.1（系统自带那个，**不需要** PowerShell 7）
- 没了。不需要 Python、Node 或任何包。

## 快速开始

```powershell
# 1. 把脚本放到某个目录，例如 C:\tools\cu\scripts\

# 2. 看一眼
powershell -NoProfile -ExecutionPolicy Bypass -File C:\tools\cu\scripts\cu.ps1 info

# 3. 按名字找控件并点击
powershell -NoProfile -ExecutionPolicy Bypass -File C:\tools\cu\scripts\cu.ps1 uia -Mode find -Name "保存"
powershell -NoProfile -ExecutionPolicy Bypass -File C:\tools\cu\scripts\cu.ps1 uia -Mode click -Name "保存"

# 4. 树是空的？先唤醒再看
powershell -NoProfile -ExecutionPolicy Bypass -File C:\tools\cu\scripts\cu.ps1 wake -Hwnd 123456
```

## 作为 agent skill 使用

`docs/SKILL.md` 就是为直接塞进 agent 上下文而写的——带 front-matter、动作表、安全规则和实测结论。
把 `docs/SKILL.md` 和 `scripts/` 放进你的技能目录即可直接用。

## 活动指示器

屏幕底部居中一行小胶囊：置顶、点击穿透、永不抢焦点。它显示 agent 当前在做什么
（`uia find 输入框 · step 12`），忙碌时脉冲，成功变绿，失败变红，闲置后淡出。

**它同时被排除在屏幕截图之外**（`SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`）——人看得见，
agent 自己的截图里没有。这很重要：agent 在不停截图，一个可见的指示器会出现在每一张里。

也正因为这个排除，指示器是**不透明而非半透明**的：Windows 拒绝对分层窗口调用
`SetWindowDisplayAffinity`（实测 `error 8`），而 WPF 只有分层窗口才有真正的逐像素透明。
圆角改用窗口区域实现。这个取舍写在了源码里，免得以后有人把它"优化"回一个 bug。

## 已知限制

- **Flutter** 应用只暴露一个 `FLUTTERVIEW` 面板；某些 Flutter 控件（尤其是自绘胶囊开关）**完全无视**
  合成指针输入，只能走键盘导航。
- UIA 矩形是**物理像素**。调用链上每个进程都必须 DPI 感知，否则坐标会被静默缩放——
  `cu.ps1` 自己设置了 per-monitor-V2，但你另外写的辅助脚本**不会继承**。
- 浏览器**外壳**（标签栏、地址栏）不在无障碍树里，只有页面内容在。

## 授权

MIT，见 [LICENSE](LICENSE)。

随包的两款哥特字体来自 [Google Fonts](https://fonts.google.com/)，采用 SIL Open Font License 1.1，
完整授权原文在 `scripts/fonts/OFL.txt`。**不需要它们可以直接删掉整个 fonts 目录**，叠层会退回到系统字体。
