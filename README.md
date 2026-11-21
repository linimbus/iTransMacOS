# iTrans

原生 macOS 截图 OCR / 划词翻译工具。常驻菜单栏，平时不显示窗口；通过全局快捷键触发后，在鼠标附近显示翻译结果。

支持**实时语音翻译**：通过快捷键监听系统声音、指定应用（会议、浏览器等）或麦克风，实时转写并翻译，显示在独立的上下分栏窗口中。

支持两种翻译引擎，可在设置中随时切换：

- **macOS 系统翻译**（默认）：使用 Apple 端侧 `Translation` 框架，无需服务器。
- **LibreTranslate**：调用自建服务，默认 `http://192.168.3.3:5000`（Swagger 文档位于 `/docs/`）。

## 功能

- **截图识别 OCR**：快捷键 → 框选屏幕区域 → 本地 Vision OCR → 自动调用所选翻译引擎 → 鼠标附近显示译文（失败时在面板中重试）
- **划词翻译**：快捷键 → 读取当前选中文本（Accessibility API，失败时回退到模拟 ⌘C）→ 翻译按钮 → 显示译文
- **多翻译引擎**：默认 macOS 系统翻译，可切换 LibreTranslate；系统语言包缺失时会弹出原生下载提示
- **实时语音翻译**：监听系统音频、指定应用或麦克风，使用 Apple SpeechAnalyzer 实时转写，并实时翻译到独立的双栏窗口
- **自动翻译**（可选）：划词后跳过按钮，直接显示译文
- **接口自动发现**：读取 `openapi.json` / Swagger `/spec`，自动识别翻译路径、字段名、请求格式和响应字段；支持手动覆盖
- **结果面板**：复制原文/译文、重新翻译、按 Esc 或点击外部关闭，文本可选中
- **多显示器与 Retina**：在任意屏幕框选，按屏幕实际像素裁剪
- **菜单栏常驻**：无 Dock 图标（`LSUIElement`），带权限状态提示

## 翻译引擎

### macOS 系统翻译（默认）

- 使用 Apple 的端侧翻译，文本不会离开本机。
- 源语言为“自动检测”时使用系统语言识别；也可以在设置里固定源语言。
- **首次翻译某个语言组合时**，macOS 会提示下载语言包。下载完成后会自动继续翻译；也可以先在设置中点击“检查系统翻译”查看状态。
- 语言包下载失败或系统不支持目标语言时，可在设置中切换为 LibreTranslate。
- 需要 macOS 26 或更高版本；本机已验证英文 → 简体中文的端侧翻译。

### LibreTranslate

- 使用现有后端（默认 `http://192.168.3.3:5000`）。
- 自动读取 `/openapi.json`、`/spec` 等规范并发现翻译接口；也支持在高级设置中手动指定。
- 当前验证的服务是 LibreTranslate 1.9.6（Flask + Flasgger），接口为 `POST /translate`（form 字段 `q` / `source` / `target`，返回 `translatedText`）。

## 实时语音翻译

- 默认快捷键 `⌥⌘L`，再次按下或点击窗口关闭按钮即停止并关闭。
- 窗口分为上下两部分：
  - 上方实时显示语音转写（含当前未定稿文字）。
  - 下方实时显示对应译文（定稿分段逐段追加，未定稿部分给出实时预览）。
- 音频来源可选：
  - **系统声音**：捕获全部系统音频（不包含 iTrans 自身）。
  - **指定应用**：只捕获所选应用（如会议软件、浏览器）的音频。
  - **麦克风**：使用系统默认输入设备，适合面对面会议、语音输入等场景。
- 语音识别使用 macOS 26+ 的端侧 `SpeechAnalyzer` / `SpeechTranscriber`，不依赖 Siri 或听写功能。
- 识别语言可选跟随系统或指定中/英/日/韩等语言；翻译目标沿用顶部设置的“目标语言”。
- 系统声音/指定应用需要“屏幕录制”权限（macOS 用它来授权系统音频捕获）；麦克风模式需要“麦克风”权限。

## 默认快捷键

| 操作 | 快捷键 |
| --- | --- |
| 截图识别 OCR | `⌥⌘O` |
| 划词翻译 | `⌥⌘T` |
| 实时语音翻译 | `⌥⌘L` |

点击设置里的快捷键框即可重新录制，需要至少一个修饰键。设置保存在 `UserDefaults`（`com.linimbus.itrans`）。

## 构建与运行

环境要求：macOS 26+、Xcode 26+（Swift 6+）。

```bash
# 构建并启动
./scripts/run.sh

# 或者只构建
./scripts/build_app.sh
open build/iTrans.app
```

生成的应用位于 `build/iTrans.app`，使用 ad-hoc 签名。也可以直接用 Xcode 打开 `Package.swift` 进行调试。

建议把 `iTrans.app` 拷贝到 `/Applications` 后再日常使用，以保证系统权限（TCC）记录稳定；每次重新构建后如果权限失效，需要在系统设置中重新勾选。

## 首次使用

1. 启动后菜单栏出现「文」字气泡图标，正常使用时没有窗口。
2. 点击菜单栏图标 → **设置…**，选择翻译引擎（默认 macOS 系统翻译）和目标语言。
   - 系统翻译首次使用时会提示下载语言包。
   - 使用 LibreTranslate 时确认服务地址（默认 `http://192.168.3.3:5000`）。
3. 授予权限：
   - **屏幕录制**：截图 OCR 和实时语音翻译（系统音频捕获）需要。首次使用时弹出系统提示；如果应用未出现在列表中，在「系统设置 → 隐私与安全性 → 屏幕录制」中手动添加 `iTrans.app`，然后重启应用。
   - **辅助功能**：划词翻译需要。在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 `iTrans`。
   - **麦克风**：麦克风实时翻译需要。首次开启麦克风监听时系统会提示授权。
4. 选中一段文字或直接按 `⌥⌘O` 框选区域开始翻译。

## LibreTranslate 接口适配

选择 LibreTranslate 引擎后，默认后端是 Flask + Flasgger（LibreTranslate）服务：

- 文档：`http://192.168.3.3:5000/docs/`
- 规范：`http://192.168.3.3:5000/spec`（Swagger 2.0）
- 翻译：`POST /translate`，`application/x-www-form-urlencoded`
  - `q`：待翻译文本
  - `source`：源语言，自动检测时传 `auto`
  - `target`：目标语言，如 `zh-Hans`、`zh-Hant`、`en`
- 响应：`{"translatedText": "...", "detectedLanguage": {...}}`

应用启动后首次翻译时会自动读取规范并发现上述接口，无需手动配置。

高级设置里可以手动指定：

- 接口路径（留空则自动发现）
- 请求方法（POST / GET）
- 文本字段、目标语言字段、源语言字段
- 译文响应路径（如 `data.translation`）
- 目标语言发送值

已内置 LibreTranslate 兼容兜底配置，即使规范文件不可读也能直接调用 `/translate`。

## 开发调试

```bash
# 本地模拟后端（Swagger 规范 + /translate）
python3 scripts/mock_server.py 5017

# 显示一个使用模拟后端的示例翻译弹窗
ITRANS_SERVER=http://127.0.0.1:5017 ITRANS_DEMO_AUTO=1 \
  ./build/iTrans.app/Contents/MacOS/iTrans --demo

# 显示区域选择蒙层（不需要屏幕录制权限）
./build/iTrans.app/Contents/MacOS/iTrans --demo-select
```

日志：

```bash
log stream --predicate 'process == "iTrans"' --level debug
```

## 项目结构

```
Sources/iTrans/
  App/            AppDelegate、启动协调器、日志
  Models/         快捷键、翻译引擎、翻译接口模型
  Services/       OCR、截图、划词、区域选择、全局快捷键、系统翻译、LibreTranslate 翻译、系统音频/麦克风捕获、实时语音识别与翻译
  Settings/       配置存储与设置界面
  UI/             状态栏、悬浮翻译面板、快捷键录制控件
Resources/        Info.plist、AppIcon.icns
scripts/          构建脚本、模拟后端
```

## 已知限制

- 截图 OCR 使用系统 Vision；识别语言随“源语言 / OCR 语言”设置变化，自动检测时使用简体中文、繁体中文和英文。
- 划词依赖目标应用支持 `AXSelectedText`；不支持时会回退到模拟 ⌘C，因此需要辅助功能权限。
- macOS 系统翻译需要系统已下载对应语言包；若下载失败，请切换为 LibreTranslate。
- 实时语音识别依赖 macOS 26+ 的端侧语音模型；如果模型未就绪，开始监听时会自动准备（可能需要网络下载）。
- 指定应用的音频捕获依赖 ScreenCaptureKit 的应用筛选；若某个应用使用独立的音频子进程，可能无法被单独捕获，此时请选择“系统声音”。
- 麦克风模式使用系统默认输入设备；如需切换输入设备，请在“系统设置 → 声音 → 输入”中修改默认设备。
- 结果面板最多显示 24 行译文，超长内容可通过“复制译文”获取完整结果。
- 目前只支持文本翻译接口，不支持文件上传或流式（SSE）接口。
- 未实现开机自启动与翻译历史。
- 实时语音翻译窗口只保留当前会话内容，关闭窗口后清空。
