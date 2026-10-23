# LiveCaption · Caption and translation

[下载 Apple Silicon 测试版 App](https://github.com/baobao700508/Caption-and-translation/releases/latest) · [源码构建](#开发者从源码构建)

macOS 原生实时字幕、原文转写与同声传译工具。以电脑播放声音为主要音源，也可加入麦克风；字幕显示在浮窗中，收起为迷你条或隐藏到菜单栏后，会话记录继续。

| 使用模式 | 处理线路 | 输出 |
| --- | --- | --- |
| 原文转写 | Google 在线转写，或 WhisperKit 本机识别 | 原文字幕、日志 |
| 书面同译 | 百炼 LiveTranslate | 原文和译文字幕、日志；服务端只生成文字 |
| 同声传译 | 百炼 LiveTranslate | 原文和译文字幕、中文译音、日志 |

字幕后台整理仅使用 **SaT 本机模型**。关闭“后台整理字幕”时，直接按服务器返回的语音活动检测（VAD）语段显示，中英文按服务端明确的关联配对。JEV 和普通聊天大模型不参与整理。

## 普通用户首次使用

使用构建好的 `LiveCaption.app` 不需要安装 Python、Homebrew、Xcode 或命令行工具。最低系统为 macOS 14.2；目前实机验收为 Apple Silicon。当前发布包使用本机 ad-hoc 签名，外部分发的 Developer ID 签名和公证尚未完成，不能将本机启动验收当作全新 Mac 的 Gatekeeper 验收。

1. 下载发布的完整 App，放到“应用程序”后打开。首次打开不会自动录音。
2. 没有配置时，在设置中点“创建本机配置”；已有配置可点“选择已有配置”。新建配置默认选择无需密钥的 Whisper 本地原文转写，不覆盖已有文件。
3. 在设置 → **本地模型**，按需点“下载并准备”：Whisper 用于本地原文转写，SaT 用于字幕段落整理。只使用云端服务且关闭整理时，两者均无需下载。
4. 等待显示实际运行验证通过。下载、依赖安装、文件校验和模型验证分阶段显示；下载模型文件时显示进度。可取消、重试及打开安装日志。SaT 首次准备会一起下载独立 Python 和所需依赖，不修改系统 Python；Whisper 不需要 Python。
5. 在“模式与音源”选择记录方式。翻译或 Google 在线转写需要填写对应地区的服务凭据并点击“保存服务凭据”；密钥保存在 macOS 钥匙串。原文转写选择 Whisper 时不需要云端密钥。
6. 选择音源后开始记录。按 macOS 提示授权系统音频录制；加入麦克风时另需麦克风权限。需要整理时，在“字幕与外观”开启“后台整理字幕”。下载完成本身不会自动开启整理或录音。

下载需要访问 GitHub、PyPI 与 Hugging Face。网络错误不会被标记成安装成功；重试会复用已经校验的模型文件。未完成的 SaT 模型不能成为可用模型；Whisper 需要下载、分词器准备及本机识别验证完成，才允许连接本地识别器。旧版 Whisper 缓存可通过下载按钮复用并补齐验证，无需手工删除或重新下载完整模型。

## 模型、依赖与空间

App 本体不携带 SaT 或 Whisper 模型。下载文件统一位于 `~/Library/Application Support/LiveCaption/`，移动或更新 App 不会删除这些文件：

```text
LiveCaption/
├── Configuration.json       # 首次创建的配置；凭据保存在钥匙串
├── SaT/
│   ├── python-…-sat-v1-arm64/ # 独立 Python 与固定版本的 SaT 依赖
│   ├── models/<模型名>/      # 校验后的 ONNX 模型与完成记录
│   └── tokenizer/           # SaT 模型共用分词器
├── WhisperKit/              # Core ML 模型、分词器与验证记录
└── InstallLogs/             # 下载与安装日志
```

默认 `sat-3l` 模型约 428 MB、分词器约 14 MB，另需 Python 和依赖空间，建议预留 2 GB。Whisper Turbo 安装后约 1.5 GB，建议预留 3 GB。以上为本机文件及模型清单对应的近似值，不是压缩下载大小保证。SaT 的多个模型共用运行环境，不重复安装依赖。

SaT 的 Python 下载地址、处理器架构、SHA-256、模型版本与模型文件哈希固定在 `Resources/LocalModels.json`；依赖版本固定在 `Resources/SaT-requirements.txt`。只从 [python-build-standalone 官方发行包](https://github.com/astral-sh/python-build-standalone)、PyPI、对应 Hugging Face 模型仓库下载。普通用户无需构建模型。模型准备完成后，SaT 使用本地路径离线推理，字幕不发送到模型下载站点。

## 开发者从源码构建

需要安装 Xcode／兼容的 Swift 5.10 以上工具链及 macOS SDK，并完成工具链首次初始化。无需先安装系统 Python、SaT、Whisper 模型或 Homebrew。构建阶段需要联网下载固定版本的第三方依赖。

```bash
git clone https://github.com/baobao700508/Caption-and-translation.git
cd Caption-and-translation
bash scripts/develop.sh
open TestResults/development/LiveCaption.app
```

`develop.sh` 下载并校验独立 Python，准备固定版本的 WebRTC SDK、Meson、Ninja 与音频静态库，执行核心检查，再构建和签名隔离开发包。它不下载 SaT 或 Whisper 模型、不覆盖桌面正式 App、不要求云端密钥。开发包可以像普通用户一样通过下载按钮准备模型。

也可从源码单独准备本地模型，与 App 使用相同下载清单和目录：

```bash
bash scripts/setup-sat.sh sat-3l
# 先完成 develop.sh，再使用同一 Swift 工具链：
swift run --scratch-path .build-selected-toolchain LiveCaptionModelSetup whisper
```

开发者使用自备 SaT 环境时，可以在“字幕与外观 → 开发者：自定义 Python 环境”设置解释器；该环境须自行安装相应依赖。默认路径自动优先使用 App 管理并验证的运行环境，兼容已有本机环境。`LIVECAPTION_MODEL_HOME` 可把独立测试的模型与安装记录隔离到另一个目录，不修改正常用户数据。

源码中的 `Resources/Configuration.example.json` 是可填写模板；也可在 App 内创建配置并填写凭据。公开录音验证脚本额外需要 `ffmpeg`，正常运行和普通构建不需要它。

结束记录并退出旧版 App 后，正式发布使用：

```bash
bash scripts/build.sh --activate --archive-legacy
```

正式构建检查、签名检查和原生界面检查通过后，发布到 `dist/LiveCaption.app`，桌面入口指向该唯一正式包。已有发布记录时须递增 `Resources/Info.plist` 中的整数 build；日常开发使用 `develop.sh` 的隔离输出。正式发布脚本使用 Python 3.12 以上；通过 `develop.sh` 准备的独立解释器也可用于执行发布脚本。

## 配置与凭据

完整可填写样例见 [Resources/Configuration.example.json](Resources/Configuration.example.json)。百炼翻译的基本配置为：

```json
{
  "pipeline": "translate",
  "translateProvider": "bailian",
  "bailianRegion": "singapore",
  "bailianWorkspaceID": "YOUR_WORKSPACE_ID",
  "bailianAPIKey": "YOUR_BAILIAN_KEY",
  "bailianTranslateModel": "qwen3.8-livetranslate-flash-realtime",
  "bailianTurnDetection": "server_vad",
  "bailianTransport": "websocket",
  "translationMode": "subtitles",
  "subtitleLayout": "bilingual",
  "targetLanguage": "zh-Hans",
  "systemAudioEnabled": true,
  "microphoneEnabled": false,
  "logDirectory": "~/Documents/LiveCaption Logs"
}
```

- `bailianRegion` 支持 `singapore` 和 `beijing`。API Key、工作空间及地区需要匹配；`bailianWorkspaceID` 是工作空间 ID，不是显示名称。
- Google 原文转写使用独立的 `apiKey`，模型由 `transcribeModel` 指定。切到本机识别时设置 `transcribeProvider: "whisperKit"`，不需要云端转写密钥。
- `translationMode: "subtitles"` 表示书面同译，`"speech"` 表示带译音同传。书面同译只请求文字，不生成付费译音后再丢弃。
- 同传请求默认音色 `Tina`，显式关闭声音克隆；服务回显必须确认检测方式、输出模态和音色设置，否则停止发送。
- `bailianTurnDetection: "auto"` 在两种翻译模式中均解析为 `server_vad`。显式指定 `speaker_detection` 的兼容路径仍保留，不能将声音变化视作服务端切换检测器的证据。
- `bailianTransport` 支持 PCM16 WebSocket 和原生 Opus WebRTC。旧配置未提供该字段时保留 WebRTC；选择传输方式不改变文字／语音输出模态。
- Google 语音翻译的兼容线路可通过 `translateProvider: "google"` 选择；其纯文字翻译配置会在连接前被拒绝。

普通配置文件修改后可使用“重读配置”，或在下一次开始记录时加载。凭据分别保存在配置文件和对应 Keychain 项中，不写入会话日志或 UserDefaults。模型、设备和设置不能替代 macOS 的实际采集授权。

## 字幕与 SaT 整理

字幕和原始日志立即更新，识别、翻译及译音播放不等待 SaT。

- **开启整理**：临时文字先放在连续尾段中；原文转写等待定稿原文，双语等待明确关联的原文和译文都定稿，再由 SaT 判断段落。双语仅在服务明确关联的语段之间换段，不按字数比例或到达顺序硬配。
- **关闭整理**：立即取消排队或执行中的本机整理，迟到结果不再应用。屏幕直接保留服务器语段，一段包含多句话时也不按句号重新切分。
- **自动保存**：开关、SaT 模型、本地 Python 路径、换段阈值及最短段落自动保存，没有单独的保存按钮。快速修改会合并写入；较早的保存不能重新开启已关闭的整理。
- **正文保真**：模型只选择切点，显示内容从原文字片截取，不能改写、翻译、删减或重复正文。完整性校验不等于语义分段质量保证；失败保留完整文字。
- **修订处理**：后续普通文字追加到尾部；供应商修改已定稿文字时，保留不受影响的前缀，重新处理受影响范围。回看前文时冻结当前显示，点击“回到最新”后恢复跟随。

```json
"captionReflow": {
  "enabled": false,
  "engine": "sat",
  "sat": {
    "model": "sat-3l",
    "pythonExecutable": "~/Library/Application Support/LiveCaption/SaT/runtime/bin/python3",
    "paragraphThreshold": 0.2,
    "minimumCharacters": 120,
    "timeoutSeconds": 120
  }
}
```

`engine` 兼容旧配置读取，当前始终使用 `sat`。默认阈值为 0.20，建议低于 0.50；超过 0.50 时会警告可能持续不分段。段落再长也不会绕过阈值按字数强切。SaT 模型概率、边界选择、推理耗时、参数和取消行为记录在分段审计日志中。字幕正文不会发送到在线整理服务。

## AI 友好记录

“记录与连接 → AI 友好设置”可配置独立的 AI Provider、Chat Completions 兼容 API 地址、API Key 和摘要模型。配置自动保存，CPA 本机模式直接读取现有 `~/.cli-proxy-api/merged-config.yaml`（或 `config.yaml`）的 `api-keys`，不读写钥匙串；手动填写的 Key 按 API 地址分别存入 macOS 钥匙串，与转写／翻译凭据独立；模型建议选择服务商提供的轻量快速型号。“测试连接”只发送一段示例文字。

开启后，新开始的会话会在索引中标为待生成，结束后在后台生成标题和两三句话的摘要，同时更新会话 Markdown 与日志根目录 `index.md`。只发送转写文字，不发送录音；长记录分段概括后合并，不阻塞收音或翻译。AI 摘要是派生内容，不能替代正文。

关闭后不调用摘要模型，也不更新 AI 索引；已发送的请求无法撤回，迟到结果不会写入记录。**重新开启不会自动补齐历史记录。**点击“补齐历史摘要与索引…”后，先查看需调用 AI 和仅需修复索引的数量，再点击“开始补齐”。已有且正文 hash 一致的摘要会复用，只修复缺失的记录标题或索引；失败项可用同一入口重试，不重复写入索引条目。

`transcript.md` 保留全文，`live.md` 保留最近十分钟；正文使用短时间戳与原文／译文标签，仅未确认、识别中或异常情况额外标注。时间为本机收到文字的 UTC 时间，不是词级音频对齐。连接信息、完整时间及修订继续保存在 JSON 日志中。

## 浮窗、音源与播放

字幕浮窗采用正文铺满的沉浸布局，右侧齿轮始终可见；悬停显示记录和更多操作，结束记录前需确认。“更多”菜单提供红色“退出程序…”选项，二次确认后先等待当前记录收尾，再完全退出。保存、复制等临时操作提示显示三秒后自动消失，新提示重新计时。字幕浮窗、迷你条和菜单栏均可打开同一个设置窗口。可选择原文、译文或双语显示；鼠标穿透时保留可交互控制条，重启后恢复非穿透。收起、隐藏和回看字幕均不会结束记录。详细操作见[沉浸字幕浮窗](Documentation/沉浸字幕浮窗.md)。

电脑声音可采集全部正在播放的应用，或限定到指定应用；浏览器标签页不作为独立应用。可加入麦克风，并选择麦克风与译音输出设备。系统采集排除本应用的译音进程；扬声器经空气进入麦克风的回授仍与设备、摆位有关。

- 麦克风启用 Apple Voice Processing，失败时显式降级为 WebRTC NS；同一路不叠加两套降噪。
- 系统声音使用内嵌 WebRTC Audio Processing 的 Low NS，可在应用内切到原音旁路。
- 实时回调只进行有界复制和环形缓冲操作；重采样、降噪、混音、网络及日志在回调外执行。
- 前端输出为 16 kHz 单声道 PCM16、100 ms 音频包；发送批次、排队时长及丢弃样本有界并记入日志。

译音使用 `AVAudioUnitTimePitch` 保留音调调速。默认积压超过 1.5 秒进入追赶，降到 0.75 秒退出；目标速度按 `1 + (待播秒数 - 0.75) / 20` 计算，最高 1.5 倍并平滑升降。速度只作用于已经收到的播放副本，原始译音及到达时间记录保持不变。待播量含本机渲染管线，不是物理扬声器的精确延迟。缓冲安全上限默认 120 秒，超过后报错并保留原音，不以丢音冒充追赶。`playbackCatchUp` 可配置关闭或调整参数。

## 日志、录音与恢复

```text
所选日志目录/
├── latest.json
└── YYYY-MM-DD/<session_id>/
    ├── session.json
    ├── events.jsonl
    ├── transcript.md
    ├── live.md
    ├── reflow-decisions.jsonl
    ├── caption-layout.json
    └── audio/
        ├── uploaded.wav
        ├── translated.wav
        ├── system-before-ns.wav
        ├── microphone-input.wav
        ├── upload-index.jsonl
        └── recording.json
```

文件按实际模式和已启用能力生成。`events.jsonl` 追加记录原始事件及修订；`transcript.md` 是整场可读正文，`live.md` 是最近十分钟快照，不删除历史。`caption-layout.json` 是派生排版，不能代替原始日志。详情见[日志契约](Documentation/日志格式.md)。

上传轨保存客户端成功提交的 PCM；WebRTC 另记录送入编码器的有效输入，收到的译音独立保存。客户端发送完成不等于服务端逐样本收货确认。设置中的“录音回听”可打开当前或历史会话的真实录音；旧会话缺失的轨道不能补回。

一场记录保留同一 `session_id`；连接切换递增 `connection_epoch`。旧连接的迟到文字保留原日志归属，不覆盖当前画面；旧译音不进入新播放队列。断线恢复只发送恢复切点之后的新音频，不补传过期排队声音；缺口单独记账。Google 保留既有轮换策略，百炼没有客户端九分钟主动轮换或课堂总时长上限。

正常停止先结束采集并排空发送，再按供应商协议结束输入和接收尾部。协议完成与译音排空分开记录；超时、断线及未确认尾段如实保留。日志写入异常会停止采集并提示错误。崩溃恢复拒绝修改仍有活动写入进程的会话，保全残缺事件行，不把未确认结果改写成完成。

## 源码结构

```text
Sources/
├── LiveCaptionApp/
│   ├── LiveCaptionApp.swift   # 应用入口与菜单
│   ├── Session/              # 会话状态、运行协调及回听
│   ├── Configuration/        # Keychain 与设置写入
│   ├── Audio/                # 设备、系统采集、前处理与播放
│   ├── Presentation/         # 浮窗、迷你条、滚动与共享控件
│   ├── Preferences/          # 完整设置及 SaT 控件
│   └── Verification/         # 原生界面和文件输入验证器
├── LiveCaptionCore/
│   ├── Configuration/        # 配置模型、兼容读取与校验
│   ├── Providers/            # 供应商协议与连接生命周期
│   ├── Networking/           # 可替换传输及 WebSocket 实现
│   ├── Captions/             # 原译文关联、SaT 协调及段落投影
│   ├── Audio/                # 音频队列、时间轴与播放追赶
│   ├── Logging/              # 会话日志、录音归档与恢复
│   └── SaTLocalRuntime.swift # 串行本机 worker 与资源定位
├── AudioBridge/              # C 环形缓冲与 C++ 降噪桥接
├── WebRTCBridge/             # 原生 WebRTC 音频设备与传输桥接
└── AoqBridge/                # 可选传输实验使用的 SDK 桥接
```

`AppSession` 的方法按职责分组在同一文件内的扩展中，保留原有 `private` 访问范围与属性初始化顺序。UI 不拥有网络或采集生命周期；供应商连接与传输分别通过既有接口测试。详细说明见[架构](Documentation/架构.md)。

## 开发与验证

完成音频依赖准备后，核心检查不需要云凭据：

```bash
bash scripts/check.sh
python3 -m unittest discover -s Tests -p '*Tests.py'
```

实际本机 SaT 推理检查可显式启用：

```bash
LIVECAPTION_SAT_TEST_PYTHON="$HOME/Library/Application Support/LiveCaption/SaT/runtime/bin/python3" bash scripts/check.sh
```

不替换正式应用的隔离构建：

```bash
LIVECAPTION_APP_PATH="$PWD/TestResults/dev/LiveCaption.app" bash scripts/build.sh
```

App 中的音源、模式及其他选择保存在本机偏好中，启动和开始记录时保留这些选择；设置里的“重新读取”或“选择配置”会主动导入 JSON，并保存为后续启动使用的偏好。

工具链默认使用 `xcode-select -p`；可通过 `LIVECAPTION_DEVELOPER_DIR` 指定工具链目录，通过 `LIVECAPTION_BUILD_PATH` 指定独立构建缓存。

应用图标源文件为 `Resources/LiveCaption.svg`。构建时使用 macOS 原生工具自动生成 16～1024 像素的 `.icns`，不需要额外图像库；菜单栏仍使用适应系统外观的单色状态图标。

退出正式应用后，检查原生窗口与状态：

```bash
bash scripts/verify-interface.sh
```

使用公开真人录音验证生产 AppSession、发送队列、字幕、日志及返回译音：

```bash
bash scripts/verify-human-app.sh subtitles /absolute/path/test-config.json
bash scripts/verify-human-app.sh speech /absolute/path/test-config.json
bash scripts/verify-human-app.sh transcribe /absolute/path/test-config.json
```

这些命令必须显式传入测试配置，才会调用其中的云服务；不默认读取桌面配置。验证包在临时目录构建，不更新桌面正式版。结果和实际上传音频保存在本机 `TestResults/`。公开样本来自 [OpenSLR LibriSpeech](https://www.openslr.org/12/)，按 CC BY 4.0 保留参考文本、来源和 PCM 哈希；干净单人朗读不代替真实课堂、远场噪声或多人验收。文件输入、实际硬件采集、物理播放、文字到达和音频到达属于不同证据范围，不能混称完成了端到端延迟验证。

音源切换与音频设备通知可单独验证，不读取云配置、不调用模型；它会实际打开麦克风和电脑音频采集：

```bash
/path/to/LiveCaption.app/Contents/MacOS/LiveCaption --verify-audio-routing /absolute/path/result.json --verification-exit
```

`Experiments/RealtimeTransports/` 及 `LiveCaptionVerify` 包含额外传输研究入口，部分需要未随仓库发布的 AOQ SDK；不自动用于正常录音。正常 App、核心检查和原生文件验证不依赖 AOQ 实验 SDK。

## 基线与发布

重构前基线：`baseline/pre-refactor-20261022`，提交 `2d0f6fe`。可在独立分支查看基线：

```bash
git switch -c inspect-baseline baseline/pre-refactor-20261022
```

结构重构的语法审计对应 `v0.1.19-build23`，在该版本的独立检出目录中运行；新增功能后的主分支不要求与旧基线 token 相同。安装包含 SwiftParser／SwiftSyntax 的 Xcode 工具链后：

```bash
python3 scripts/verify-source-refactor.py baseline/pre-refactor-20261022
```

该检查比较所有 Swift 声明的 token、会话属性初始化顺序、桥接源码和既有测试；只允许文件整理及会话方法分组，不会把函数体、常量或条件变化当作等价改动。

版本只在 `Resources/Info.plist` 定义。正式发布串行执行检查、构建、签名和同一二进制的原生界面验证；检查失败、源码在验证中变化或仍有应用实例运行时拒绝覆盖。旧包保存在本机 `Releases/Archive/`，实际版本、SHA-256 和证据路径见 `Releases/current.json`。详见[版本管理与发布](Documentation/版本管理与发布.md)。

本机完整迁移保留录音、测试资料、依赖、缓存和历史包；旧开发路径仅作为指向正式目录的兼容链接，不维护第二份源码。公开仓库排除凭据、本机配置、录音、会话日志、模型、依赖和构建产物。通用离线回归测试保留在 `Tests/`；机器专用诊断与一次性测试放入被 Git 忽略的 `LocalOnly/`，不作为公开验证入口。第三方许可随应用打包，位于 `Resources/`。当前为本机 ad-hoc 签名开发包；外部分发所需的签名、公证及目标系统验收独立处理。

[本地模型与首次使用验证](Documentation/本地模型与首次使用验证.md)说明准备流程的实际验收边界。[文档索引](Documentation/README.md)区分当前工程说明与历史调研记录。历史报告描述其对应版本与样本，不作为当前功能列表、默认配置或服务承诺。
