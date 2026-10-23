# 实时传输对照

该目录保留 Network.framework WebSocket、百炼 AOQ 和 WebKit WebRTC 对照。正式应用的百炼连接为 `LiveCaptionCore/BailianWebRTCTransport.swift` 与原生 `WebRTCBridge`；Google 仍用 URLSession WebSocket。正式应用不会加载本目录的 AOQ 或 WebKit 实现。WebKit 在本机后台音频上下文被挂起，因此不用于产品。当前测量见 `Documentation/延迟修复与实测结果.md`。

验证器必须传入一份有限长度的 16 kHz、单声道 PCM16 WAV。它不打开麦克风、不播放声音，使用与应用相同的两秒有界队列及积压合并规则。上传成功轨保留客户端已完成发送的 PCM，不代表远端消费确认。

```bash
LIVECAPTION_TRANSPORT=websocket swift run LiveCaptionVerify /absolute/path/recording.wav translate /absolute/path/test-config.json subtitles
LIVECAPTION_TRANSPORT=native-webrtc swift run LiveCaptionVerify /absolute/path/recording.wav translate /absolute/path/test-config.json speech
LIVECAPTION_TRANSPORT=aoq swift run LiveCaptionVerify /absolute/path/recording.wav translate /absolute/path/test-config.json speech
```

测试必须显式传入配置，不默认读取桌面凭据。机器专用 Python 探针和旧测试启动脚本不随仓库提供。普通应用链路验证使用根目录 README 中的 `scripts/verify-human-app.sh`。

AOQ 使用官方 macOS SDK 1.3.0 与 Opus 插件。SDK 来源为[官方下载页](https://help.aliyun.com/zh/model-studio/realtime-sdk-download)，媒体和事件接入遵循[实时翻译 AOQ 指南](https://help.aliyun.com/zh/model-studio/real-time-translation-using-aoq-access-qwen-livetranslate)。SDK 位于 `Vendor/aoq/`，仅用于本地实验；对外分发前需另行确认授权与打包要求。

AOQ 的 `uploaded.wav` 是交给 SDK 的 PCM；`aoq-input-observed.wav` 是 SDK 推流观察回调中非 `autoGenMute` 的 PCM；`aoq-published.wav` 包含该回调中的全部帧。后两者均不是远端解码录音。包含自动静音的回调轨不能直接解释为上传时间轴被拉长。SDK 网络统计记录到 `transport.aoq_stats`，包括 RTT、丢包率和发送码率。

`protocol_pass` 只表示收到所需结果和收尾；`realtime_transport_pass` 还要求无丢包、样本数完整，以及最大排队和写入时间均小于两秒。原生 WebRTC 另外要求有效输入全部消费、underflow 为零、配置前 RTP 包为零。两者通过仍不能证明词级字幕延迟、翻译正确率或译音音质。
