# LiveCaption

正式使用入口统一为桌面 `LiveCaption.app`，指向本工程 `dist/LiveCaption.app`。源码版本只在 `Resources/Info.plist` 定义，实际发布版本、程序校验值与检查记录见 `Releases/current.json`。发布与归档规则见[版本管理与发布](Documentation/版本管理与发布.md)。真实课堂的 WebSocket／WebRTC 对照、返回延迟及播放追赶验证见[课堂测试报告](TestResults/sg-classroom-15m-20261022/report.md)。早期断线与 JEV 评估见[历史验证报告](Documentation/断线定位与JEV评估.md)。

macOS 原生菜单栏课堂字幕工具。电脑播放声音为主音源，可选加入麦克风；字幕浮于屏幕，收起窗口后仍继续记录。

| 线路 | 模型 | 输出 |
| --- | --- | --- |
| Transcribe | Google `gemini-3.5-transcribe-live` 或本地 WhisperKit | 原文字幕、实时日志 |
| Translate · 同译 | 百炼 `qwen3.8-livetranslate-flash-realtime` | 可选原文、译文或双语字幕、日志 |
| Translate · 同传 | 同上 | 字幕、译音、日志 |

百炼书面同译使用 `output_modalities: ["text"]`，服务端不生成译音，也不提交音色或声音克隆设置；同传使用 `["text", "audio"]`、默认音色 `Tina`，显式关闭声音克隆且不提交复刻频率。纯原文记录请选择独立 Transcribe。Google Translate 可通过 `translateProvider: "google"` 保留，但仅允许同声传译；其仅文字配置会在连接前被拒绝，避免生成付费译音后在本机丢弃。`provider.configuration` 日志记录服务回显的 `output_modalities` 和 `audio_output_requested`；仅文字时不记录译音采样率。

`bailianTransport` 可设为 `websocket` 或 `webrtc`；未配置的旧文件保留 WebRTC。两条路径都使用相同模型、目标语种和输出模态回显核验，日志记录实际选择。WebSocket 输入 PCM16，WebRTC 输入经 Opus 编码；网络路径不决定是否生成译音。

译音通过 `AVAudioUnitTimePitch` 保音调播放。`playbackCatchUp` 默认启用：待播原速媒体量超过 1.5 秒进入追赶，降到 0.75 秒退出；目标速度为 `1 + (待播秒数 - 0.75) / 20`，最高 1.5 倍，平滑升降。速度只作用于已经收到的播放副本，原始译音和云端到达记录不变。`playback.catch_up` 记录库存、速度、目标和样本数。库存按至多 100 ms 的未播放完 PCM 块计数，含渲染管线，不是物理发声延迟。缓冲安全上限默认 120 秒，超过后明确报错停播并继续保存原音；不再在 5 秒时清空译音。可在配置中设置 `enabled: false` 恢复原速，或调整 `maximumRate`（1–2）等参数。

## 使用

1. Translate 填写桌面 `LiveCaption配置.json` 的 `bailianAPIKey`、`bailianWorkspaceID`；`bailianRegion` 默认为 `singapore`，也可填 `beijing`。Key、工作空间与地区必须匹配；工作空间 ID 是 API 地址中的 WorkspaceId，不是空间名称。Transcribe 继续使用原 `apiKey`（Google）。可修改 `logDirectory`。
2. 打开 `dist/LiveCaption.app`，点击菜单栏字幕图标，再点“开始记录”。应用不在打开时自动采集。
3. 系统首次请求权限时，允许 LiveCaption 录制系统音频；启用麦克风时另需麦克风权限。
4. 浮窗顶部的齿轮、收起后的迷你控制条、菜单栏的“设置…”都能打开同一个独立设置窗口；应用激活时可用 `⌘,`。重新打开应用也会调出设置。
5. “收起字幕”保留迷你条，迷你条可展开字幕、开始／结束、打开设置；“隐藏到菜单栏”在浮窗的更多菜单中，仍可从菜单栏恢复。两种操作都不结束记录。
6. 设置分为模式与音源、字幕与外观、音频处理、记录与连接；原文／译文／双语只在同译、同传适用。
7. 设置 → 记录与连接 → 录音回听，可结束记录后直接播放实际上传音频、系统声降噪前和麦克风输入对比轨；也可打开录音文件夹或选择历史录音。新版开始的会话自动保存，旧录音不能补回。
8. 上课中途点“复制 AI 追课提示”，交给获得日志目录读取权限的 Codex 或其他 AI；可在会话运行中读取，无需等下课。

配置文件保存后可点“重读配置”，或在下一次开始时读取改动。若 macOS 阻止读取桌面，可用“选择配置”选取这个 JSON 文件；选择结果通过文件 bookmark 保留。Google 与百炼 Key 分别导入各自的 Keychain 项；不写入课堂日志或 UserDefaults。桌面文件由用户保管，应用不会擅自清空它。日志目录在会话中途更换时，从下一场会话生效。

## 字幕分段与重排模型

设置 → 字幕与外观 → 字幕智能分段，可选择 JEV、普通大模型或 SaT。普通大模型使用 OpenAI 兼容 Chat Completions，JEV 使用独立判断接口；两者会把文字发送到相应文字服务。SaT 在本机推理，无需整理服务密钥。这些模型只处理已经生成的文字，不替换语音识别或翻译模型。

字幕和原始日志立即更新。JEV 的临时文字保持一个连续尾段，单语等待原文定稿，双语等待明确关联的两轨均定稿；只固定模型确认完整的前缀阅读块。不完整尾句等待后文，后文不重切已固定段落，定稿改字在原位置更新并保留段落身份。SaT 使用独立本地协调器，等待连续 final 前缀后选择切点，双语只在明确关联组之间分段。普通大模型保留自己的临时前缀和尾段接续逻辑。已有内容完整可滚动，不折叠、不用省略号隐藏正文。回看前文时冻结当前排版，点“回到最新”再跟随新字幕。

普通大模型返回普通 JSON 切点，通过提示词说明格式，不使用 `response_format`、JSON Schema 或工具调用。显示文字始终从输入原片段切出，本地拒绝越界、乱序、遗漏或重复覆盖，并逐字节验证两条文字完整一致。这个检查保证不改字，不能保证每个语义配对都正确。请求失败最多重试一次；迟到结果必须仍与原文字节匹配。JEV 从最早的待整理正式前缀开始，以有限窗口处理；未整理部分照常完整显示。模型选择、分数、采用与拒绝原因均进入分段日志。

桌面 JSON 的独立配置如下；`apiKey` 属于文字重排服务，与 Google、百炼的 Key 分开：

```json
"captionReflow": {
  "enabled": true,
  "baseURL": "http://127.0.0.1:8317/v1",
  "apiKey": "YOUR_TEXT_MODEL_KEY",
  "model": "gpt-6-luna",
  "reasoningEffort": "low",
  "timeoutSeconds": 12,
  "maxRetries": 1
}
```

不支持 `reasoning_effort` 的服务将 `reasoningEffort` 留空即可。API 地址填到 `/v1` 这一层；应用追加 `/chat/completions` 或 `/models`。默认示例关闭重排；本机交付配置已启用 CPA。重排 Key 按 API 地址独立存入 Keychain，桌面配置仍由用户保管。

系统声音可从运行中应用列表选择全部或指定应用。指定应用必须正在播放；采集覆盖其音频 helper，浏览器标签页不视为独立应用。麦克风与译音输出默认跟随系统设备，也可在应用内选择。当前本机开发包未启用 App Sandbox，采用本地 ad-hoc 签名；尚不是 App Store 或已公证分发包。

## 音频处理

- 麦克风启用时自动打开 Apple `AVAudioEngine` Voice Processing，不要求用户手动开“语音突显”。原生处理失败时显式降级为 WebRTC NS；同一路不叠加两个降噪器。
- 系统声音内嵌 WebRTC APM，默认 Low NS，关闭 AEC 和 AGC。应用内可切为原音旁路；只处理发送给模型的副本。
- 实时回调将音频写入预分配的 C 原子环形缓冲；重采样、降噪、混音、JSON、网络和日志在回调之外执行。
- 两路按 host time 对齐、浮点混音、峰值保护，最终以 16 kHz mono PCM16、100 ms 包发送。队列有上限，丢帧与连接中断写入日志。
- 系统采集排除本应用译音进程；扬声器经空气进入麦克风的回授仍需独立验收。建议组合输入优先使用耳机。

Apple 原生 Voice Processing 可能对其他播放声音执行 ducking，应用设为最低强度并关闭高级 ducking。公开接口没有完全关闭的保证。近讲和远场讲师效果必须分别测量，不能根据 API 能力推断真实识别质量。

## 实时日志

```text
所选目录/
  latest.json
  YYYY-MM-DD/<session_id>/
    session.json
    events.jsonl
    transcript.md
    live.md
    caption-layout.json  # 启用重排且成功时的派生排版快照
    audio/
      uploaded.wav
      system-before-ns.wav  # 启用系统声时
      microphone-input.wav # 启用麦克风时
      upload-index.jsonl
      recording.json
```

`events.jsonl` 追加记录识别假设及修订；`transcript.md` 为整场当前可读结果；`live.md` 为最近十分钟快照，不删除整场历史。Transcribe 的 final 替换 interim，不重复追加。`latest.json` 指向最近会话，含活动状态、更新时间和序号。日志异常会停止采集并给出错误，避免用户误以为课堂仍在完整记录。

`caption-layout.json` 为最新连接代次的派生显示快照，不能代替整场原始日志。重排不覆盖 `transcript.md` 或 `live.md` 的原文；AI 追课仍应优先读取这些持续更新的正文。停止后正在进行的最后一次重排可完成快照写入，下一场会话会清除旧的排版任务。

录音独立保存在 `audio/`；上传 WAV 与发送字节相同，输入轨可用于对照前处理。发送成功不等于服务端消费确认，失败发送及重连缺口须结合索引和事件日志判断。

具体字段、修订规则、读取示例与 AI 提示见 [课堂日志读取契约](Documentation/日志格式.md)。

模型切换或轮换保留 session_id 和 sequence，递增 connection_epoch。Google 计划轮换约九分钟触发；百炼不设置没有官方依据的定时轮换或课堂总时长上限。遇到重连、输入变化或不完整尾部时保留明确标记。恢复能力不代表无限无损连接。百炼停止时发送 `session.finish`，最多等待 20 秒的 `session.finished`，再结束日志；超时、断连或旧连接未完整收尾时标记 `tail_incomplete`。Google Transcribe 发送 `audioStreamEnd`，最多等待十秒并以正式 `inputTranscription` 确认末段输出；这不是逐采样点收货回执。切换同译／同传会重建云会话，旧连接继续接收尾部结果；切换期间可能存在缺口。

## 构建与验证

需要 Apple Swift 工具链和 macOS SDK。默认使用 `xcode-select -p` 指定的工具链；可通过 `LIVECAPTION_DEVELOPER_DIR` 选择开发目录。构建缓存位于 `.build-selected-toolchain`；更换工具链时用 `LIVECAPTION_BUILD_PATH` 指向另一缓存目录，避免混用编译器产物。

```bash
bash scripts/build.sh
bash scripts/check.sh
bash scripts/verify-live.sh
```

构建脚本自动在工程内建立 Meson/Ninja 工具环境，从固定 SHA256 的 freedesktop WebRTC APM 2.1 源码构建静态库，Abseil 版本及归档校验由其 wrap 文件固定。应用运行时不依赖 Python、Meson、Homebrew 或外部降噪服务。第三方许可包含在 app 的 Resources 中。

`check.sh` 在本机运行协议、修订、跨连接日志、实际文件追读、音频环形缓冲和真正的 WebRTC NS 检查，不需要云凭据。它使用普通 Swift 可执行测试入口，便于仅安装 Command Line Tools 的机器运行。

`verify-live.sh translate` 使用公开 LibriSpeech 真人录音，真实调用当前配置的翻译线路；`verify-live.sh translate "$HOME/Desktop/LiveCaption配置.json" speech` 验证译音，`verify-live.sh transcribe` 验证独立转写。这是核心线路检查，不含原生字幕 UI。

`bash scripts/verify-human-app.sh subtitles` 验证实际 AppSession 发送队列、百炼返回、原生字幕、重排和运行中日志；将 `subtitles` 换为 `speech` 或 `transcribe` 可检查另外两个模式。测试使用 76.145 秒真人朗读，七个连续语句按顺序各输入一次，不循环、不合成、不播放，也不打开麦克风。结果与实际上传 WAV 保存在 `TestResults/human-*/`；可运行 `python3 scripts/analyze-human-reflow.py <result.json>` 分别核对输入字节、字幕保真、首字时间与后台整理耗时。首次准备数据需要网络与 ffmpeg，语音请求会使用所选配置的云 API。

公开样本来自 [OpenSLR LibriSpeech test-clean](https://www.openslr.org/12/)，CC BY 4.0；文件、原始逐句文本、时间范围和 PCM 哈希保存在 `TestResults/fixtures/librispeech/provenance.json`。干净的单人朗读可复现输入完整性与字幕处理，不能代替真实课堂、远场噪声和多人同时说话的验收。字幕分段结果见 [字幕智能分段与真人录音验证](Documentation/字幕智能分段与真人录音验证.md)。当前断线恢复与 Google 收尾结果见 [断线恢复与收尾验证](Documentation/断线恢复与收尾验证.md)。

应用另提供开发诊断参数 `--verify-audio <fixture.wav> <result.json>`，仅采集由验证器启动的 afplay 进程，经真实 Core Audio tap、WebRTC NS 和格式转换统计 PCM 指标，不调用云模型，也不保存环境或麦克风录音。`--verify-classroom <fixture.wav> <result.json> <transcribe|translate>` 使用独立测试日志目录，验证真实播放器采集、Google 返回、字幕状态、收起后追读，以及 Translate 的播放／静音切换；测试不改写桌面配置或生产日志。真实课堂质量、扬声器 AEC、全屏覆盖、多设备切换及长时间运行的验证状态见 `Documentation/验证状态.md`。

## 百炼 API 配置

```json
{
  "pipeline": "translate",
  "translateProvider": "bailian",
  "bailianAPIKey": "YOUR_BAILIAN_KEY",
  "bailianWorkspaceID": "YOUR_WORKSPACE_ID",
  "bailianRegion": "singapore",
  "bailianTranslateModel": "qwen3.8-livetranslate-flash-realtime",
  "translationMode": "subtitles",
  "subtitleLayout": "bilingual",
  "targetLanguage": "zh-Hans"
}
```

源语种由模型自动识别，`zh-Hans`／`zh-Hant` 目标统一映射到接口的 `zh`；这不保证简繁体输出偏好。翻译线路同时返回原文识别；原文与译文按各自消息 ID 保存，不假设二者逐句一一对应。`response.text.done` 仍可能对应中断响应，只有 `response.done.status == completed` 才标为定稿。

输入继续使用现有 16 kHz 单声道 PCM16，译音按 24 kHz PCM16 播放。应用默认使用已回显确认的 `server_vad`（`bailianTurnDetection` 可显式改为 `speaker_detection`，其 threshold 固定 0.5）；应用内降噪继续在发送前执行。当前适配器专门处理 Qwen 3.8 协议，不把 Qwen 3.5 的 snapshot 当成 delta。旧 JSON 未指定 `translateProvider` 时保留 Google 线路；桌面迁移配置显式指定百炼。

官方依据：[客户端事件](https://help.aliyun.com/zh/model-studio/live-translator-client-events)、[服务端事件](https://help.aliyun.com/zh/model-studio/live-translator-server-events)、[模型与接入地区](https://help.aliyun.com/zh/model-studio/qwen3-5-livetranslate-flash-realtime)。

## 界面检查

`--verify-interface <result.json> --verification-exit` 在原生应用内验证浮窗、迷你条、设置、隐藏恢复、鼠标穿透回退和模式状态，不启动采集或调用云 API。真实鼠标点击和截图检查单独记录，见 [交互设计与验收](Documentation/交互设计与验收.md)。
