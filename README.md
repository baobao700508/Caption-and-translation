# LiveCaption · Caption and translation

macOS 原生实时字幕、原文转写与同声传译工具。以电脑播放声音为主要音源，也可加入麦克风；字幕显示在浮窗中，收起为迷你条或隐藏到菜单栏后，课堂记录继续。

| 使用模式 | 处理线路 | 输出 |
| --- | --- | --- |
| 原文转写 | Google 在线转写，或 WhisperKit 本机识别 | 原文字幕、日志 |
| 书面同译 | 百炼 LiveTranslate | 原文和译文字幕、日志；服务端只生成文字 |
| 同声传译 | 百炼 LiveTranslate | 原文和译文字幕、中文译音、日志 |

字幕后台整理仅使用 **SaT 本机模型**。关闭“后台整理字幕”时，直接按服务器返回的语音活动检测（VAD）语段显示，中英文按服务端明确的关联配对。JEV 和普通聊天大模型不参与整理。

## 环境

- macOS 14.2 或更新系统；当前实机验证环境为 Apple Silicon。
- Xcode 或兼容的 Swift 工具链及 macOS SDK；包使用 Swift tools 5.10。
- Python 3.12 或更新版本，用于依赖准备、构建和验证脚本。
- 启用 SaT 时需要独立的本机 Python 环境；首次使用所选模型需要下载模型。
- 使用公开录音验证脚本时需要 `ffmpeg`；正常运行应用不依赖 `ffmpeg`。

语音采集、降噪、网络连接和播放使用原生代码。SaT 在本机 Python worker 中推理；WhisperKit 使用 Core ML，本机识别模型在准备完成后才开始接收音频。

## 快速开始

```bash
git clone https://github.com/baobao700508/Caption-and-translation.git
cd Caption-and-translation
cp -n Resources/Configuration.example.json "$HOME/Desktop/LiveCaption配置.json"
```

编辑桌面的配置文件，填写对应服务的凭据。已有配置可继续使用，也可在设置中通过“选择配置”指定另一个 JSON 文件。

首次从源码构建时，先准备音频静态库，供发布前的核心检查使用：

```bash
python3 scripts/build_audio.py
```

需要本机字幕整理时，再准备 SaT：

```bash
bash scripts/setup-sat.sh
```

结束正在进行的记录并退出旧版应用后，构建并打开：

```bash
bash scripts/build.sh --activate --archive-legacy
```

构建入口会下载并校验固定版本的 WebRTC SDK，必要时构建独立降噪库，再执行核心检查、签名检查和原生界面检查。通过后发布到 `dist/LiveCaption.app`，桌面 `LiveCaption.app` 指向该唯一正式包。已有发布记录时，重新正式发布前须递增 `Resources/Info.plist` 中的整数 build；开发构建可使用下文的隔离输出目录。

启动应用不会自动录音。首次使用时，按 macOS 提示授权系统音频录制；启用麦克风时另需麦克风权限。

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

普通配置文件修改后可使用“重读配置”，或在下一次开始记录时加载。凭据分别保存在配置文件和对应 Keychain 项中，不写入课堂日志或 UserDefaults。模型、设备和设置不能替代 macOS 的实际采集授权。

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
    "paragraphThreshold": 0.5,
    "minimumCharacters": 120,
    "timeoutSeconds": 120
  }
}
```

`engine` 兼容旧配置读取，当前始终使用 `sat`。阈值越高，倾向于切出更少的段落。SaT 模型概率、边界选择、推理耗时、参数和取消行为记录在分段审计日志中。字幕正文不会发送到在线整理服务。

## 浮窗、音源与播放

字幕浮窗、迷你条和菜单栏均可打开同一个设置窗口。可选择原文、译文或双语显示；鼠标穿透时保留可交互控制条，重启后恢复非穿透。收起、隐藏和回看字幕均不会结束记录。

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

工具链默认使用 `xcode-select -p`；可通过 `LIVECAPTION_DEVELOPER_DIR` 指定工具链目录，通过 `LIVECAPTION_BUILD_PATH` 指定独立构建缓存。

退出正式应用后，检查原生窗口与状态：

```bash
bash scripts/verify-interface.sh
```

使用公开真人录音验证生产 AppSession、发送队列、字幕、日志及返回译音：

```bash
bash scripts/verify-human-app.sh subtitles
bash scripts/verify-human-app.sh speech
bash scripts/verify-human-app.sh transcribe
```

这些命令会调用配置中的云服务，结果和实际上传音频保存在本机 `TestResults/`。公开样本来自 [OpenSLR LibriSpeech](https://www.openslr.org/12/)，按 CC BY 4.0 保留参考文本、来源和 PCM 哈希；干净单人朗读不代替真实课堂、远场噪声或多人验收。文件输入、实际硬件采集、物理播放、文字到达和音频到达属于不同证据范围，不能混称完成了端到端延迟验证。

`Experiments/RealtimeTransports/` 及 `LiveCaptionVerify` 包含额外传输研究入口，部分需要未随仓库发布的 AOQ SDK；不自动用于正常录音。正常 App、核心检查和原生文件验证不依赖 AOQ 实验 SDK。

## 基线与发布

重构前基线：`baseline/pre-refactor-20261022`，提交 `2d0f6fe`。可在独立分支查看基线：

```bash
git switch -c inspect-baseline baseline/pre-refactor-20261022
```

安装包含 SwiftParser／SwiftSyntax 的 Xcode 工具链后，可对照重构的源码语法：

```bash
python3 scripts/verify-source-refactor.py baseline/pre-refactor-20261022
```

该检查比较所有 Swift 声明的 token、会话属性初始化顺序、桥接源码和既有测试；只允许文件整理及会话方法分组，不会把函数体、常量或条件变化当作等价改动。

版本只在 `Resources/Info.plist` 定义。正式发布串行执行检查、构建、签名和同一二进制的原生界面验证；检查失败、源码在验证中变化或仍有应用实例运行时拒绝覆盖。旧包保存在本机 `Releases/Archive/`，实际版本、SHA-256 和证据路径见 `Releases/current.json`。详见[版本管理与发布](Documentation/版本管理与发布.md)。

本机完整迁移保留录音、测试资料、依赖、缓存和历史包；旧开发路径仅作为指向正式目录的兼容链接，不维护第二份源码。公开仓库排除凭据、本机配置、录音、课堂日志、模型、依赖和构建产物。第三方许可随应用打包，位于 `Resources/`。当前为本机 ad-hoc 签名开发包；外部分发所需的签名、公证及目标系统验收独立处理。

[文档索引](Documentation/README.md)区分当前工程说明与历史调研记录。历史报告描述其对应版本与样本，不作为当前功能列表、默认配置或服务承诺。
