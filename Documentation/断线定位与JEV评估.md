# LiveCaption 断线定位与 JEV 重排评估

交付版本：**0.1.5（build 6）**，2026 年 10 月 21 日。双击桌面 `LiveCaption.app` 打开；桌面 `LiveCaption配置.json` 已使用新的默认检测方式，已有凭据与 Luna 重排配置保留。

## 断线的触发点

重复断线与**云端语段结束、发送最终消息并进入下一语段**高度相关。`server_vad` 对这组真人录音经常在约 34 秒、67 秒处切段；故障发生在其中某个交接处，ICE 再过约六秒才报告失联。因此用户看到的是近似固定时间点断线。这里的 33 秒左右间隔是样本观察，不是已证实的 API 固定时限。

最明确的一次记录为：音频到 67.328 秒时服务端结束语段，依次发来原文定稿、译文定稿、音频完成、内容完成和输出项完成。之后 `response.done` 只到达第一个分片：

- SCTP DATA 的 TSN 为 `546551531`，分片标志为 begin，没有 end，承载 784 字节数据。
- 客户端立即发出有效 SACK，累计确认到同一个 TSN；CRC 正确，接收窗口仍有约 4.7 MB，并未耗尽。
- 剩余分片没有到达，STUN 探测回复及传输反馈也停止；远端的部分定时 RTCP 报告仍继续到达，本地音频编码也仍在运行。
- 约六秒后 ICE 报告 disconnected；本地随后启动恢复。没有观察到服务端在停滞之前发送 SCTP ABORT。

证据将范围缩小到**百炼实时连接在语段交接时的传输／互操作问题**。它不足以确定远端具体代码、网络中的哪一跳，或证明客户端确认包已被远端收到；不能据此宣称已经修复了阿里内部的某个缺陷。它也不是“全部网络数据完全消失”的证据。

控制实验支持这个范围：

| 对照条件 | 实际结果 |
| --- | --- |
| 原生 M155，关闭字幕重排 | 仍在约 75 秒失联 |
| 原生 M155，普通 Opus，去掉 RED 冗余协商 | 仍在约 75 秒失联，试改已撤回 |
| 原生 M154 | 仍在约 40 秒失联，生产继续使用 M155 |
| 独立 Python aiortc 1.15.0，`server_vad` | 也出现语段收尾停滞：82.635 秒输入仅交付到 69.66 秒，未完成会话 |
| 同一原生实现，164.485 秒录音，`server_vad` | 约 74.9 秒失联；恢复时明确丢弃 3.5 秒 |
| 独立 aiortc，`speaker_detection` | 164.485 秒全部交付，收到 `session.finished` |

`server_vad` 也有完整通过的运行，因此不能说每次切段必断。失败记录与成功记录均保留，没有以重试后的成功覆盖失败。

## 应用的具体改动

### 两种翻译模式统一改用可配置的说话人检测

`Configuration.bailianTurnDetection` 默认设为 `speaker_detection`，按官方契约发送固定 `threshold: 0.5`。同声传译与书面同译共用 `BailianProtocol.setup`，都检查 `session.updated` 回显的检测方式、阈值、模型、目标语言、格式和输出模态；配置不一致就不开始发音频。`server_vad` 仍可在配置文件中显式选择，用于兼容排查。

这是在已复现触发条件上采用另一条官方支持的检测路径。单个说话人的云端语段会更长，但原文和译文的 delta 持续到达，字幕与日志立即更新；后台重排仍能整理尚未定稿的标点前缀，不等待整段结束。换说话人的样本也观察到了新的语段边界并完成输出。

[百炼客户端事件文档](https://help.aliyun.com/zh/model-studio/live-translator-client-events)将 `speaker_detection` 列为 Qwen 3.8 的默认检测方式，`server_vad` 为另一选项。阈值 0.5 不是本机音量的 50%，不能拿它直接解释麦克风电平。

收音、Apple Voice Processing、降噪、采样率与 Google Transcribe 模型没有更换。

### 服务器完成与译音排空分开处理

原实现收到 `session.finished` 后只等八秒译音尾部。真人长录音实测中，服务器已经发送全部文字与会话完成事件，RTP 仍在正常传来可听译音；八秒上限会把这些声音截断，并报告收尾失败。

现在原生桥接先记录 `playout.draining`，继续交付译音，采用单调时钟测量实际等待时间。至少等待 500 ms，并在译音连续静默 350 ms 后完成；最长等待三十秒。正常排空记录 `playout.drained`，超时记录 `playout.timeout` 并明确标为不完整。

协议层只在原生桥接确认已经收到服务端终止事件后，提供一次最长 32 秒的本地排空等待窗；一般服务端不回应的情况仍受原协议超时限制，重复通知不能无限延长等待。实测一个长录音需要 **9.893 秒**排空，换说话人录音需要 **8.564 秒**，均超过旧上限。

### 断线缺口仍明确丢弃，不积压补传

恢复切点、750 ms 过期丢弃、最多 500 ms 单批发送、有界输入队列及旧连接代次隔离继续生效。这里没有把缺失的声音伪装成已上传，也没有通过无限缓存掩盖断线。

同一 164.485 秒 `server_vad` 自然断线对照中，56,000 个样本、即 **3.5 秒**被明确剔除；剩余样本与原录音对应位置逐字节一致，恢复后采集到客户端提交最大 **110 ms**，没有重放断线前的旧声音。旧连接另有 1,600 个已交给客户端、尚未进入编码器观察轨的样本，单独保留证据边界。

最终版本还主动断线一次，并额外推迟 3.5 秒才重连。连同实际重新建连，共丢弃 112,000 个样本、即 **7.0 秒**；全部输入恰好由已提交和明确丢弃覆盖。恢复后最大提交年龄 **107 ms**，编码器 underflow 为零，新原文、中文与译音均返回，最后连接收尾完成。整场仍标为有缺口，不能算完整上传。

## 真人录音验收

音源为 [OpenSLR LibriSpeech test-clean](https://www.openslr.org/12/)，许可 CC BY 4.0。长录音为 `6930/75918` 的连续二十条、共 164.485 秒；换说话人录音为其前 45 秒与说话人 `1320/122617` 的三条不同录音拼接，共 64.1 秒，选择顺序与参考文本有记录。弱音测试仅将前 25 秒降低 18 dB，平均 RMS 约 −46.6 dBFS。每次均按真实时间有限输入，没有合成语音、循环、硬件麦克风或扬声器。

测试经过实际 AppSession、音频发送队列、真实云 API、字幕状态、后台重排、实时日志与音频存档。它验证传输和应用处理，不替代远场收音、物理扬声器回授或整堂课时长的验收。

| 测试 | 结果 |
| --- | --- |
| 164.485 秒同声传译 | 无断线、无丢弃；2,631,761 个上传和编码器输入样本逐字节一致；首原文 3.851 秒、首译文 3.890 秒、首译音 4.195 秒；15 次重排、39 组双语字幕；收尾完成 |
| 64.1 秒换说话人，同声传译 | 无断线、无丢弃；观测到说话人交接处切段；首原文 3.833 秒、首译文 3.864 秒；7 次重排；译音完整排空 |
| 25 秒低音量，书面同译 | 无断线、无丢弃；首原文 3.823 秒、首译文 3.861 秒；未生成译音；收尾完成 |
| 最终 build 6，64.1 秒书面同译 | 完整输入、无断线、运行中日志可读；7 次重排；无译音；收尾完成 |
| 最终 build 6，主动断线并延迟恢复 | 缺口逐样本对账通过；旧输入不补传；恢复后最大提交年龄 107 ms；最后连接正常结束 |
| 离线回归 | 38 项、0 失败；覆盖两种检测方式和输出模式的配置确认、错误阈值拒绝、译音排空与普通超时分离，以及既有 Google 收尾、队列、日志与重排检查 |

长录音的英文参考文本为 443 个归一化词，识别编辑距离为 6，词错率约 1.35%；这是单一有声书样本，不是模型总体准确率或翻译准确率。中英字幕重排后分别与云端文字逐字节一致。首字幕时间从文件开始输入计算，不能代表每个词结束后的延迟；本地字幕状态投影约 0.04～0.13 ms，也不能冒充物理屏幕刷新延迟。

Google 的代码未受检测方式调整影响；本次离线回归覆盖其收尾逻辑，真实 Google 调用证据仍来自[Google 与恢复验收报告](断线恢复与收尾验证.md)，不是本次重新调用的结果。

## JEV 替代重排模型的可行性

**可以作为候选切点判断器接入，但不能只把现有 Chat Completions 模型名改成 JEV。** 已通过本机配置的 OpenRouter 凭据真实调用 `typesafe/jev-1.14`，返回版本为 `typesafe/jev-1.14-20261014`。凭据未复制到应用桌面配置。

现用 Luna 根据双语文字返回切点；JEV 使用 `state + questions`，返回 `noul` 或 `choice` 判断及概率。原型先生成合法候选边界，批量询问“这里是否适合分段”与“对应哪个中文边界”，再由本地程序筛选单调递增的成对切点。两种文字始终从原始字节切片，禁止模型生成正文。因此内容不变由程序保证，语义对齐仍需评估。

在同一组实际中英转写上，两条轨道各 17 个标点片段、32 个判断问题的结果如下：

| 原型 | 请求耗时 | API 返回费用（美元） | 输出组数 | 内容保留 |
| --- | --- | --- | --- | --- |
| 使用片段编号与整体上下文 | 0.397 秒 | $0.000486 | 5 | 两轨逐字节一致 |
| 问题中加入相邻中英原句 | 0.367 秒 | $0.001265 | 7 | 两轨逐字节一致 |

第二种方案改善了切分，但仍会把几个完整意思合并成大段，尤其是最后一组。当前原型同时要求自然边界概率和所选对应边界概率不低于 0.8；不确定则保留较大块。这两个样本不足以证明 JEV 比 Luna 分得更好，也不足以估算课堂平均费用。没有拿整段一次调用与 Luna 的增量多次调用直接比较速度或价格。

适合的接入方案是新增独立 `engine: jev` 适配器及其 API 地址、模型与凭据字段，沿用先显示后整理、一次重试、过期任务取消和原文完整性验证。还需补充中英句数不同、ASR 标点错误和中文长句的对齐评测。TypeSafe 官方说明模型主要针对英语优化；中英双语质量必须用实际材料判断。

**生产重排仍使用原来的 Luna；JEV 当前为可复现实验原型，未进入设置页、未偷偷替换默认模型。**

接口来源：[TypeSafe 模型](https://docs.typesafe.ai/models)、[System One API](https://docs.typesafe.ai/api/system-one)、[OpenRouter JEV 接入](https://openrouter.ai/blog/tutorials/how-to-use-jev/)。

## 证据与代码入口

- [语段交接故障：最后分片与确认](../TestResults/ice-investigation-2/native-vad-control/boundary-audit.json)、[3.5 秒缺口对账](../TestResults/ice-investigation-2/native-vad-control/recovery-audit.json)。
- [164 秒同传](../TestResults/ice-investigation-2/native-speaker-drain/boundary-audit.json)、[双语排版与参考文本](../TestResults/ice-investigation-2/native-speaker-drain/metrics.json)。
- [换说话人同传](../TestResults/ice-investigation-2/native-speaker-change/boundary-audit.json)、[低音量书面同译](../TestResults/ice-investigation-2/native-speaker-low-subtitles/boundary-audit.json)。
- [最终构建主动断线](../TestResults/human-speech-20261021-150717/recovery-audit.json)、[最终构建书面同译](../TestResults/human-subtitles-20261021-150802/result.json)。
- [JEV 编号方案](../TestResults/ice-investigation-2/jev-1.14/result.json)、[JEV 相邻原句方案](../TestResults/ice-investigation-2/jev-1.14-literal/result.json)。
- [构建](../TestResults/ice-investigation-2/final-build.txt)、[38 项回归](../TestResults/ice-investigation-2/final-checks.txt)。

运行中的 `events.jsonl`、`transcript.md`、`live.md`，以及 `audio/uploaded.wav`、`audio/webrtc-input-observed.wav`、`audio/translated.wav` 均保留在每份结果的 `log_path` 中。上传轨表示客户端接受的 PCM，观察轨表示进入编码器的输入；两者都不是服务端解码回传。

实现入口为 `Configuration.swift`、`BailianConnection.swift` 和 `WebRTCBridge.mm`。排查工具 `Experiments/NetworkDiagnostics/` 只在测试进程中记录 UDP 类型、SCTP 分片序号、确认和校验结果，不保存地址、SDP、凭据或原始报文载荷，也不注入正常发布应用。`scripts/analyze-connection-boundary.py`、`scripts/analyze-recovery.py` 可重算时间与输入对账；JEV 原型位于 `Experiments/SubtitleSegmentation/probe_jev.py`。

当前证据证明所选检测路径通过了这些有限真人样本，以及客户端不再按八秒截断正常译音。尚未证明所有网络条件与整堂课长度下都不会断线，也未得到服务端内部根因确认；如果再发生失联，仍按明确缺口、只继续新声音的策略处理。
