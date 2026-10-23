import SwiftUI
import AppKit
import LiveCaptionCore

struct PreferencesView: View {
    @ObservedObject var session: AppSession
    @State private var inputDevices: [AudioDeviceChoice] = []
    @State private var outputDevices: [AudioDeviceChoice] = []
    @State private var applications: [(id:String,name:String)] = []
    private let languages = [("zh-Hans","中文"),("en","英语"),("ja","日语"),("ko","韩语"),("fr","法语"),("de","德语"),("es","西班牙语")]
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:6) {
                Label("LiveCaption",systemImage:"captions.bubble.fill").font(.headline).padding(.horizontal,12).padding(.bottom,18)
                ForEach(SettingsSection.allCases) { section in
                    Button { session.settingsSection = section } label: {
                        Label(section.title,systemImage:section.icon).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,10)
                            .background(session.settingsSection == section ? Color.teal.opacity(0.15) : .clear,in:RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain).accessibilityValue(session.settingsSection == section ? "已选中" : "")
                }
                Spacer()
                Text("收起字幕后，记录继续。\n结束记录后，日志仍保留。").font(.caption).foregroundStyle(.secondary).padding(12)
            }.padding(14).frame(width:180).background(.quaternary.opacity(0.4))
            Divider()
            VStack(spacing:0) {
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text(session.settingsSection.title).font(.title2.weight(.semibold))
                        Text(sectionDescription).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("显示字幕",action:session.showSubtitles).controlSize(.small)
                }.padding(22)
                Divider()
                Form { sectionContent }.formStyle(.grouped)
                Divider()
                VStack(alignment:.leading,spacing:8) {
                    if let feedback = session.feedback { Text(feedback).font(.caption).foregroundStyle(.teal) }
                    HStack {
                        VStack(alignment:.leading,spacing:3) {
                            StatusIndicator(session:session)
                            Text(session.connectionSummary).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(); RecordingButton(session:session)
                    }
                }.padding(.horizontal,22).padding(.vertical,14)
            }
        }.frame(minWidth:740,minHeight:540).tint(.teal).task { await refreshDevices() }
    }
    private var sectionDescription:String {
        switch session.settingsSection {
        case .session: return "选择记录方式，以及要听到的声音。"
        case .appearance: return "调整字幕内容、阅读大小与浮窗操作。"
        case .audio: return "应用内自动处理声音，可按输入设备调整。"
        case .models: return "按需下载模型及完整运行环境，准备好后再开始记录。"
        case .records: return "查看课堂日志位置与当前服务连接。"
        }
    }
    @ViewBuilder private var sectionContent:some View {
        switch session.settingsSection {
        case .session: sessionSettings
        case .appearance: appearanceSettings
        case .audio: audioSettings
        case .models: LocalModelsSettings(session:session,models:session.localModels)
        case .records: recordSettings
        }
    }
    private func audioBinding(_ keyPath:WritableKeyPath<Configuration,Bool>) -> Binding<Bool> {
        Binding(get:{session.config[keyPath:keyPath]},set:{ value in
            session.config[keyPath:keyPath] = value
            Task { await session.changeInput() }
        })
    }
    private var sessionSettings:some View {
        Group {
            if !session.configurationReady {
                Section("首次使用") {
                    Text("① 创建配置，或选择已有配置。② 在“本地模型”下载需要的模型。③ 选择音源并开始；macOS 会在采集时请求授权。")
                        .font(.callout)
                    Button("创建本机配置") { Task { await session.createInitialConfiguration() } }
                        .disabled(session.configurationLoading).accessibilityIdentifier("create-initial-configuration")
                    Button("选择已有配置…") { Task { await session.chooseConfiguration() } }
                }
            }
            Section("记录模式") {
                ModeSelector(session:session).labelsHidden()
                Text(session.recordingMode.detail).font(.caption).foregroundStyle(.secondary)
                if session.config.pipeline == .transcribe {
                    Picker("识别方式",selection:$session.config.transcribeProvider) {
                        Text("Google 在线").tag(TranscriptionProvider.google)
                        Text("Whisper 本地 · GPU").tag(TranscriptionProvider.whisperKit)
                    }.disabled(session.running || session.busy).onChange(of:session.config.transcribeProvider) { _,_ in session.preferencesChanged() }
                    if session.config.transcribeProvider == .whisperKit {
                        Picker("原文语言",selection:$session.config.localWhisper.language) {
                            Text("英语").tag("en"); Text("中文").tag("zh"); Text("自动检测").tag("")
                        }.disabled(session.running || session.busy).onChange(of:session.config.localWhisper.language) { _,_ in session.preferencesChanged() }
                        Text("Whisper Turbo 在本机通过苹果 GPU 识别，声音和字幕不发到云端。首次使用请先在“本地模型”下载并准备。").font(.caption).foregroundStyle(.secondary)
                        Button("下载／检查 Whisper") { session.showSettings(.models) }
                    }
                }
                if session.config.pipeline == .translate {
                    Picker("翻译成",selection:$session.config.targetLanguage) {
                        ForEach(languages,id:\.0) { Text($0.1).tag($0.0) }
                        if !languages.contains(where:{$0.0 == session.config.targetLanguage}) { Text(session.config.targetLanguage).tag(session.config.targetLanguage) }
                    }.disabled(session.running || session.busy).onChange(of:session.config.targetLanguage) { _,_ in session.preferencesChanged() }
                    LabeledContent("字幕显示") { LayoutSelector(session:session).frame(width:250) }
                    if session.config.subtitleLayout == .source {
                        Text("当前仅显示原文，译文仍写入日志。选择“译文”或“双语”即可显示翻译。").font(.caption).foregroundStyle(.orange)
                    }
                    if session.running { Text("目标语言可在结束本次记录后更改。").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if session.configurationReady && session.config.provider != .whisperKit {
                Section("云服务连接") {
                    if session.config.provider == .bailian {
                        Picker("服务地区",selection:$session.config.bailianRegion) {
                            Text("新加坡").tag(BailianRegion.singapore);Text("北京").tag(BailianRegion.beijing)
                        }.onChange(of:session.config.bailianRegion) { _,_ in session.preferencesChanged() }
                        TextField("工作空间 ID",text:$session.config.bailianWorkspaceID)
                            .onChange(of:session.config.bailianWorkspaceID) { _,_ in session.preferencesChanged() }
                        SecureField("百炼 API Key",text:$session.config.bailianAPIKey)
                        Text("API Key 与工作空间必须属于所选地区。书面同译只请求文字；同声传译另请求译音。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { SecureField("Google API Key",text:$session.config.apiKey) }
                    Button("保存服务凭据") { Task { await session.saveCloudCredentials() } }
                    Text("凭据保存在 macOS 钥匙串，不写入字幕与安装日志。本地模型下载不需要这些密钥。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(session.running || session.busy)
            }
            Section("声音来源") {
                Toggle("电脑播放声音",isOn:audioBinding(\.systemAudioEnabled)).disabled(session.busy || (session.running && session.config.systemAudioEnabled && !session.config.microphoneEnabled))
                if session.config.systemAudioEnabled {
                    Picker("采集范围",selection:$session.config.applicationBundleID) {
                        Text("全部电脑声音").tag("")
                        ForEach(applications,id:\.id) { Text($0.name).tag($0.id) }
                        if !session.config.applicationBundleID.isEmpty && !applications.contains(where:{$0.id == session.config.applicationBundleID}) {
                            Text("所选应用未运行").tag(session.config.applicationBundleID)
                        }
                    }.disabled(session.running || session.busy).onChange(of:session.config.applicationBundleID) { _,_ in session.preferencesChanged() }
                    if session.running { LevelMeter(title:"电脑电平",level:session.systemLevel) }
                }
                Toggle("加入麦克风",isOn:audioBinding(\.microphoneEnabled)).disabled(session.busy || (session.running && session.config.microphoneEnabled && !session.config.systemAudioEnabled))
                if session.running && session.config.microphoneEnabled { LevelMeter(title:"麦克风电平",level:session.microphoneLevel) }
                Text(session.running ? "至少保留一个音源。更换采集范围需结束本次记录。" : "推荐使用电脑播放声音；需要记录现场讲话时，再加入麦克风。").font(.caption).foregroundStyle(.secondary)
            }
            SessionNotice(session:session)
        }
    }
    private var appearanceSettings:some View {
        Group {
            Section("字幕内容") {
                if session.config.pipeline == .translate { LayoutSelector(session:session).labelsHidden() }
                else { Text("原文转写模式仅显示原文；切到同译或同传后，可选原文、译文或双语。").font(.callout).foregroundStyle(.secondary) }
                LabeledContent("字号",value:"\(Int(session.fontSize)) pt")
                Slider(value:$session.fontSize,in:16...44,step:1).accessibilityLabel("字幕字号")
                Text("字幕预览 · 今天我们将讨论储能。").font(.system(size:session.fontSize)).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading).padding(12).foregroundStyle(.white).background(.black.opacity(session.overlayOpacity),in:RoundedRectangle(cornerRadius:10))
                LabeledContent("背景不透明度",value:"\(Int(session.overlayOpacity*100))%")
                Slider(value:$session.overlayOpacity,in:0.45...1).accessibilityLabel("字幕背景不透明度")
            }
            Section("浮窗操作") {
                Toggle("字幕鼠标穿透",isOn:$session.passthrough)
                Text("开启后点击会穿过完整字幕窗。可在菜单栏关闭穿透；迷你控制条始终可操作。重启应用后自动关闭穿透。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("展开字幕",action:session.showSubtitles)
                    Button("收起为迷你条",action:session.collapseSubtitles)
                    Button("重置位置") { session.overlay?.resetPosition() }
                }
                Button("恢复默认外观") { session.fontSize = 25; session.overlayOpacity = 0.85; session.passthrough = false }
            }
            CaptionReflowSettings(session:session)
        }
    }
    private var audioSettings:some View {
        Group {
            Section("自动声音处理") {
                Toggle("电脑声音轻度降噪",isOn:audioBinding(\.systemNoiseSuppression)).disabled(session.busy)
                Text("WebRTC 轻度降噪，只处理发给模型的副本，不改变电脑原声播放。").font(.caption).foregroundStyle(.secondary)
                Toggle("麦克风自动语音处理",isOn:audioBinding(\.microphoneVoiceProcessing)).disabled(session.busy)
                Text("麦克风启用时自动使用 Apple Voice Processing；无需去系统菜单开启“语音突显”。").font(.caption).foregroundStyle(.secondary)
                Picker("电脑声道",selection:$session.config.systemChannelMode) {
                    Text("自动合并（推荐）").tag(ChannelSelection.auto); Text("仅左声道").tag(ChannelSelection.left); Text("仅右声道").tag(ChannelSelection.right)
                }.disabled(session.busy).onChange(of:session.config.systemChannelMode) { _,_ in Task { await session.changeInput() } }
            }
            Section("音频设备") {
                Picker("麦克风",selection:$session.config.microphoneDeviceUID) {
                    Text("跟随系统输入").tag("")
                    ForEach(inputDevices) { Text($0.name).tag($0.id) }
                    if !session.config.microphoneDeviceUID.isEmpty && !inputDevices.contains(where:{$0.id == session.config.microphoneDeviceUID}) { Text("所选设备未连接").tag(session.config.microphoneDeviceUID) }
                }.disabled(session.busy).onChange(of:session.config.microphoneDeviceUID) { _,_ in Task { await session.changeInput() } }
                Picker("译音输出",selection:$session.config.outputDeviceUID) {
                    Text("跟随系统输出").tag("")
                    ForEach(outputDevices) { Text($0.name).tag($0.id) }
                    if !session.config.outputDeviceUID.isEmpty && !outputDevices.contains(where:{$0.id == session.config.outputDeviceUID}) { Text("所选设备未连接").tag(session.config.outputDeviceUID) }
                }.disabled(session.busy).onChange(of:session.config.outputDeviceUID) { _,_ in Task { await session.changeInput() } }
                Button("刷新设备列表") { Task { await refreshDevices() } }
                Text("记录中更换设备会重建采集；短暂中断会标记在日志中。").font(.caption).foregroundStyle(.secondary)
            }
            Section("译音音量") {
                Slider(value:$session.volume,in:0...1).accessibilityLabel("译音音量")
                Text(session.recordingMode == .interpretation ? "同传模式正在使用此音量。" : "只有同声传译模式会播放译音。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var recordSettings:some View {
        Group {
            Section("课堂记录") {
                Text(session.currentDirectory?.path ?? session.config.logDirectory).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("打开日志目录",action:session.revealLogs)
                    Button("更改保存位置…",action:session.chooseLogDirectory).disabled(session.running || session.busy)
                }
                Button("复制 AI 追课提示",action:session.copyCatchUpPrompt).disabled(session.currentDirectory == nil)
                Text("开始后持续保存，收起字幕不影响记录。AI 可随时读取 live.md；整场内容保存在 transcript.md。更改保存位置需先结束记录。").font(.caption).foregroundStyle(.secondary)
            }
            Section("录音回听") {
                Text("每次记录自动保存上传音频，以及降噪前的系统声／麦克风输入。与文字日志存放在同一会话目录。").font(.caption).foregroundStyle(.secondary)
                if session.running {
                    Button("结束记录并回听上传音频") { Task { await session.endAndListen() } }.disabled(session.busy)
                    Text("结束后回听，避免播放的录音再次进入系统采集或麦克风。").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(RecordingTrack.allCases) { track in
                        HStack {
                            Button(session.recordingPlayback == track.rawValue ? "停止播放" : "播放") {
                                if session.recordingPlayback == track.rawValue { session.stopRecordingPlayback() }
                                else { session.playRecording(track) }
                            }.disabled(!session.hasRecording(track) || session.busy)
                            Text(track.title)
                            Spacer()
                            if session.recordingPlayback == track.rawValue { Label("播放中", systemImage:"speaker.wave.2.fill").font(.caption).foregroundStyle(.teal) }
                        }
                    }
                }
                HStack {
                    Button("打开录音文件夹", action:session.revealAudio).disabled(session.currentDirectory == nil)
                    Button("选择历史录音…", action:session.chooseAudioSession).disabled(session.running || session.busy)
                }
                Text("模型输入录音保留交给客户端连接的 16 kHz 单声道 PCM16，不做回听增强。百炼连接随后编码为 Opus 传输，因此该录音不是服务端解码回传；原生编码器的输入另存为对照轨。同传另存返回的译音。麦克风对比轨可能已经过 Apple 语音处理；缺口见日志。").font(.caption).foregroundStyle(.secondary)
                Text("WAV 保存在本机；上传轨约 115 MB／小时，每条对比轨约 346 MB／小时；麦克风有对齐前后两条对比轨。旧会话未保存的录音无法恢复。").font(.caption).foregroundStyle(.secondary)
            }
            Section("服务连接") {
                LabeledContent("当前服务",value:session.connectionSummary)
                LabeledContent("模型") { Text(session.config.model).font(.caption.monospaced()).textSelection(.enabled) }
                Text("音频发送至上述服务；课堂文字保存在本机。API Key 不写入日志。").font(.caption).foregroundStyle(.secondary)
                LabeledContent("配置文件") { Text(session.selectedConfigurationURL.lastPathComponent).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("打开配置…",action:session.openConfiguration)
                    Button("选择配置…") { Task { await session.chooseConfiguration() } }.disabled(session.running || session.busy)
                    Button("重新读取") { Task { await session.reloadConfiguration() } }.disabled(session.running || session.busy || session.configurationLoading)
                }
                if let problem = session.errorMessage ?? session.configurationProblem { Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                else if session.configurationLoading { Label("正在读取配置；如 macOS 正在等待文件授权，请完成系统提示。",systemImage:"hourglass").font(.caption).foregroundStyle(.secondary) }
                else { Label("配置已就绪",systemImage:"checkmark.circle.fill").font(.caption).foregroundStyle(.teal) }
            }
        }
    }
    private func refreshDevices() async {
        var seen = Set<String>()
        applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }.compactMap { app in
            guard let id = app.bundleIdentifier,seen.insert(id).inserted else { return nil }; return (id,app.localizedName ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let devices = await Task.detached { (availableAudioDevices(input:true),availableAudioDevices(input:false)) }.value
        inputDevices = devices.0; outputDevices = devices.1
    }
}
private struct LevelMeter:View {
    let title:String
    let level:Float
    var body:some View { HStack { Text(title).font(.caption); ProgressView(value:min(Double(level)*4,1)).tint(.teal) }.accessibilityElement(children:.combine) }
}
