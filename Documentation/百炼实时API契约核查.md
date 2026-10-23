# 百炼 Qwen3.8 实时翻译 API 契约核查

核查日期：2026-10-22。范围为官方模型、事件、WebSocket／WebRTC 文档与 LiveCaption 接入代码。本报告区分官方明确保证、官方示例行为与本地代码推论，不把协议检查当作真实延迟验收。

## 结论

现有接入的模型名、北京／新加坡端点格式、Bearer 鉴权、`translation.language = zh`、3.8 输出模态字段及增量事件名称，与官方协议相符。正式翻译线路使用原生 WebRTC：音频走 RTP 媒体轨，文字与控制走 DataChannel；WebSocket append 仅作为对应协议参考。没有发现协议要求每包等待识别结果、等待翻译完成，或等待十余秒才能继续上传。代码核验并记录服务端配置回显、按采集时间记录发送、区分原文与译文，并按服务标识关联源译消息；这些记录不等于翻译延迟或语义准确率已得到验证。

## 连接时长与连续课堂

当前 LiveTranslate 的模型卡、接入指南、客户端／服务端事件及通用 WebRTC 接入说明中，未查到明确的单连接墙钟时长上限。模型卡公布的 53,248 上下文、49,152 最大输入与 4,096 最大输出是 token 限制，不能直接当作允许的课堂分钟数。[模型卡](https://help.aliyun.com/zh/model-studio/qwen3-8-livetranslate-flash-realtime)、[模型接入](https://help.aliyun.com/zh/model-studio/qwen-livetranslate-model-access)、[WebRTC 接入](https://help.aliyun.com/zh/model-studio/realtime-webrtc-access)。

Qwen-Omni-Realtime 指南写明单次会话最长 120 分钟，但那是另一类对话模型，不能直接套到当前翻译模型。[Omni 指南](https://help.aliyun.com/zh/model-studio/realtime)。APP 因而不再为百炼设置固定九分钟主动轮换，也不设置课堂总时长上限；实际连接失败仍记录缺口并恢复。同一用户会话的字幕、录音与日志不因恢复而另起一堂课。未公开上限不代表连接无限有效，一小时课堂的实际稳定性仍需对应时长实测。

官方 Qwen3.8 发布说明介绍了音频文本交织、Thinker–Talker 与长上下文消歧，并公布 LAAL 平均滞后 2.3 秒；没有说明服务会故意保持 6～10 秒的输出积压。平均滞后也不是每句最大延迟保证。静音后追上和长录音延迟平台可以证明观测行为，不能单独证明内部调度意图。[Qwen 发布说明](https://qwen.ai/blog?id=qwen3.8-livetranslate)。

## 连接、格式与发送

| 核查项 | 官方契约及代码对应 |
| --- | --- |
| 模型 | `qwen3.8-livetranslate-flash-realtime`；不可混用文件翻译 API 或 3.5 事件解析器。见[模型卡](https://help.aliyun.com/zh/model-studio/qwen3-8-livetranslate-flash-realtime)。 |
| 地域、工作空间 | `wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime?model=…`；新加坡对应 `ap-southeast-1`。Key、工作空间与地址地域一致。`Configuration.bailianURL` 的结构吻合。见[接入指南](https://help.aliyun.com/zh/model-studio/qwen3-5-livetranslate-flash-realtime)。 |
| 鉴权 | WebSocket 请求头 `Authorization: Bearer …`；现代码符合。[接入指南](https://help.aliyun.com/zh/model-studio/qwen3-5-livetranslate-flash-realtime)。 |
| 音频 | 输入 16 kHz、单声道、16 bit 原始 PCM；输出 24 kHz、单声道、16 bit PCM。原始 PCM 不包含 WAV 文件头。项目将采样转换结果编码为 little-endian Int16；上传 WAV 只能作本地容器回听，不能把头送进 append。[接入指南](https://help.aliyun.com/zh/model-studio/qwen3-5-livetranslate-flash-realtime)。 |
| 帧与节奏 | 官方示例读取 1600 个样本后即发送，等于 100 ms／3200 字节；发送线程独立于接收循环。它是示例选择，文档未将 3200 B 声明成唯一合法帧长，也未公布 append 最大字节数。[接入指南](https://help.aliyun.com/zh/model-studio/qwen3-5-livetranslate-flash-realtime)。 |
| append | `input_audio_buffer.append.audio` 是 Base64；持续发送，由服务端判断语音与生成时机。文档未列逐包 ACK／信用窗口／每包需要等待 response 的机制。[客户端事件](https://help.aliyun.com/zh/model-studio/live-translator-client-events)。 |

项目 `AudioFrontend` 按 3200 B 产包，和示例相同。`WebSocketTransport.send` 等待的是 URLSession 写入完成，不是百炼逐包消费确认；`AudioArchive.sent` 因而只能证明同一字节序列在本地 send 返回成功，不能证明远端已经识别。持续积压时，必须分别记录准备、开始发送、写入完成时间，以及队列丢弃数量；不能把成功发送轨拼接后较短的时长误称成正常完整输入。

## 会话配置和版本边界

3.8 使用 `session.output_modalities`：书面同译传 `["text"]`，同声传译传 `["text","audio"]`。目标中文用 `session.translation.language = "zh"`。省略目标语种会落到默认英语。3.8 原文 ASR 始终开启，源语种自动识别。[模型卡](https://help.aliyun.com/zh/model-studio/qwen3-8-livetranslate-flash-realtime)、[客户端事件](https://help.aliyun.com/zh/model-studio/live-translator-client-events)。

3.8 的检测配置位于 `session.audio.input.turn_detection`。`type` 支持 `speaker_detection`（默认）或 `server_vad`；`speaker_detection.threshold` 固定为 0.5，用来过滤非有效人声。不能拿 3.5 顶层 VAD 的可调范围、默认 0.2 和手动提交逻辑直接套到 3.8。正式应用采用 `server_vad`，并检查服务端回显；不设置文档未为 3.8 声明的灵敏度参数。0.5 不是 PCM 振幅“低于半量程即静音”的定义。[客户端事件](https://help.aliyun.com/zh/model-studio/live-translator-client-events)。

3.5 使用顶层 `modalities`、`sample_rate`、`input_audio_format`、`turn_detection`，`input_audio_transcription` 可开关。其 `.text` 事件带 `text/stash`；3.8 使用 `.delta`，两者不可混为一种流式文本语义。[模型卡](https://help.aliyun.com/zh/model-studio/qwen3-8-livetranslate-flash-realtime)、[服务端事件](https://help.aliyun.com/zh/model-studio/live-translator-server-events)。

`session.created` 后发送配置；收到 `session.updated` 并通过 `confirmedSession` 校验后才发音频。校验覆盖模型、目标语言、输入输出格式、模态及实际语段检测策略，非敏感字段写入 `provider.configuration`；不符合预期就报配置未生效，不能显示“翻译中”继续运行。[服务端事件](https://help.aliyun.com/zh/model-studio/live-translator-server-events)。

官方说明 `session.update` 可更新配置，但没有明确保证已开始输出后能无缝更改模态，或定义切换中途输出的归属。项目 `changeMode` 开新连接、把新配置确认后再切换、旧连接单独收尾，是保守实现；不能把本地关闭播放器当成服务端纯文字模式已切换。

## 接收与收尾

| 内容 | 3.8 事件与处理规则 |
| --- | --- |
| 原文 | `conversation.item.input_audio_transcription.delta.delta` 顺序累加；`.completed.transcript` 覆盖为完整结果。 |
| 纯文字译文 | `response.text.delta.delta` 累加；`.done.text` 完整内容。 |
| 译音对应文字 | `response.audio_transcript.delta.delta` 累加；`.done.transcript` 完整内容。 |
| 译音 | `response.audio.delta.delta` 解码后为音频分片；`.audio.done` 不带完整音频。 |
| 响应完成 | `response.done.response.status` 决定该响应完成状态；单个 text/audio done 也可能出现在中断场景，不能直接视为整个会话完成。 |
| 关联 | `conversation.item.created.previous_item_id` 连接同一 VAD 段的原文 item 和 assistant 译文 item；两者 item_id 并不相同。 |

以上事件与字段见[服务端事件](https://help.aliyun.com/zh/model-studio/live-translator-server-events)。当前解析器区分源／译轨，增量不等待 final；通过 `conversation.item.created.previous_item_id` 保留原始 item_id 与源译关联。相同关联只说明服务端把它们归在同一组，不能证明音频标记恰好位于首词发音，也不能证明翻译没有遗漏。

停止时先停输入，再发 `session.finish`，持续接收尾部原文／译文／译音，收到 `session.finished` 后断开。当前 `finish()` 等待结束事件的方向正确；超时应保留未确认尾部，不能宣称完整保存。[客户端事件](https://help.aliyun.com/zh/model-studio/live-translator-client-events)。

`error` 与 `conversation.item.input_audio_transcription.failed` 都应保留 code/message（脱敏），而 HTTP 拒绝、WebSocket 关闭、写入超时应与模型响应错误分开。现代码把所有 `.error` 设置为连接失败；应检查是否因可局部处理的失败触发重连与音频缺口。该风险需实际事件证据，不能只凭症状认定。

## 延迟与断续的定位要求

1. 记录采集末样本到发送开始、发送开始到写入返回、最后已发送样本到首原文／首译文／首译音的时间。分别报告，不把首文本时间当作整句翻译延迟。
2. 对同一份合成或公开音源，仅一次顺序播放；核对原始轨、处理轨、发送成功轨的时长、样本覆盖和丢弃区间。原始轨正常但发送轨缺失，先修发送链路；不能归因模型漏听。
3. 启动与模式切换都确认回显 `language=zh`。若回显正确、译文事件确实为中文而 UI 是英文，检查布局是否仅原文、轨道绑定及旧代次字幕；若回显英语，先修配置链路。
4. 同一帧长比较 URLSession 与官方 `websocket-client` 的单次 write 耗时和完整率，排除客户端实现／链路阻塞。不得靠无限缓存把缺失变成二十秒排队，也不得无提示丢弃后称实时稳定。

北京与新加坡模型卡均列 10 RPM、100,000 TPM；这是请求和 Token 限制，不是每分钟只准发 10 条 append。官方说明限流表现为请求拒绝，不能将长时间成功写入阻塞直接认定为限流。[模型卡](https://help.aliyun.com/zh/model-studio/qwen3-8-livetranslate-flash-realtime)、[限流说明](https://help.aliyun.com/zh/model-studio/rate-limit)。

## 检测器、压缩与原生传输可选项

未找到官方将 `speaker_detection` 定义为低吞吐模式、限制连续音频并发处理，或保证换 `server_vad` 即降低延迟的说明。3.8 文档支持的最小检测器对照是 `audio.input.turn_detection.type = server_vad`，省略阈值；其可调阈值范围、静音时长的客户端范围没有和 3.5 一样明确列出，应以回显和实测确认。WebSocket 的 `input_audio_format = opus` 仅明确标注适用 3.5；3.8 回显的 nested `audio.input.format` 不能直接推成可配置 Opus。没有找到官方对 WS 压缩扩展或 permessage-deflate 的保证。[客户端事件](https://help.aliyun.com/zh/model-studio/live-translator-client-events)。

### AOQ 可在 macOS 原生接入

官方提供 Objective-C `AoqClientEngine`／`AoqEngineDelegate`，支持自定义 PCM 输入。官方 v1.3.0 的 macOS 下载包已只读核验：SDK 和 Opus 均有 arm64、x86_64，arm64 Mach-O 的 `LC_BUILD_VERSION.minos` 为 11.0；SDK plist 的旧最低版本字段是 10.13，部署下限应以二进制依赖为准。下载来源为[官方下载页](https://help.aliyun.com/zh/model-studio/realtime-sdk-download)：[AoqClientSdk.framework.zip](https://g-adoc.alcasset.com/media/maas_docs/sfm-cn/common/files/6a4b3c2d1e0f9d85.zip)、[PluginOpus.framework.zip](https://g-adoc.alcasset.com/media/maas_docs/sfm-cn/common/files/6a4b3c2d1e0f9d84.zip)。解包应保留 framework 符号链接。

既有采集可保留：`startAudioCapture:` 的 `isExternal=YES`，通过 `addAudioExternalStream:config:` 和 `pushAudioExternalStreamData:data:` 输入原有 PCM；设置真实采样率／样本数，关闭额外 3A，不在本地回放输入。实时建议 10 ms 一帧；返回 110 表示 SDK 外部缓冲区满，等待后重试同帧。模型 JSON 由 `sendDataMsg:` 发送，`onDataMsg:` 接收；媒体不再重复装入 append。见[macOS API](https://help.aliyun.com/zh/model-studio/aoq-macos-sdk-reference)、[自定义音频采集](https://help.aliyun.com/zh/model-studio/aoq-custom-audio-capture)。

北京凭据兑换接口为 `POST https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api/v1/webrtc/realtime?model=qwen3.8-livetranslate-flash-realtime`；请求头使用现有 Bearer Key、`Content-Type: application/json`、`x-dashscope-rtc-transport: moq`，请求体可为 `{}`，公网 IP 可选。返回临时 token、sid、Relay 地址和证书指纹。官方部署形态是业务 AppServer 保管 Key；已有本地 BYOK 应用技术上可执行同一兑换请求，这是协议推论，尚非该应用的认证实测。没有额外 AccessKey 或新账号凭据要求。[Token 鉴权](https://help.aliyun.com/zh/model-studio/realtime-token-authentication)。

AOQ 的 3.8 专用指南保留相同模态、目标语言和字幕事件；连接成功后先通过 Data 发送 `session.update`，等待 `session.updated` 再开媒体上行。纯字幕只需下行 Data，同传另订阅 Audio。译音从媒体轨获取，不可再把同一 `response.audio.delta` 重复播放。结束输入后通过 Data 发 `session.finish`，等待 `session.finished` 再释放。见[官方 AOQ 实时翻译指南](https://help.aliyun.com/zh/model-studio/real-time-translation-using-aoq-access-qwen-livetranslate)。

官方概述支持 LiveTranslate 的 WebRTC，但本次未找到专为该 Realtime API 提供的 macOS 原生 WebRTC SDK；不能把浏览器示例或另一个 RTC 产品的 SDK 当作已核实原生方案。AOQ 有可核验的原生二进制，因此比未经确认的 WebRTC 原生迁移更具体；仍需对同一音源实际测量，不能承诺更换即解决。[Realtime API 概述](https://help.aliyun.com/zh/model-studio/realtime-api-overview)。
