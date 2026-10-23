import SwiftUI
import AppKit
import LiveCaptionCore

struct CaptionReflowSettings:View {
    @MainActor static func enabledBinding(session:AppSession,fileURL:URL?=nil)->Binding<Bool> {
        Binding(get:{ session.config.captionReflow.enabled },set:{ session.setReflowEnabled($0,fileURL:fileURL) })
    }
    @MainActor static func parameterBinding<Value>(session:AppSession,_ path:WritableKeyPath<SaTReflowConfiguration,Value>,fileURL:URL?=nil)->Binding<Value> {
        Binding(get:{ session.config.captionReflow.sat[keyPath:path] },set:{ value in
            var sat=session.config.captionReflow.sat;sat[keyPath:path]=value
            session.setSaTConfiguration(sat,fileURL:fileURL)
        })
    }
    @ObservedObject var session:AppSession
    var body:some View {
        Section("SaT 字幕整理") {
            Toggle("后台整理字幕",isOn:Self.enabledBinding(session:session)).accessibilityIdentifier("reflow-enabled")
            Text("开启后使用 SaT 在本机整理段落；关闭后按服务器返回的语音活动检测（VAD）语段显示。开关和下方参数均自动保存。").font(.caption).foregroundStyle(.secondary)
            Picker("SaT 模型",selection:Self.parameterBinding(session:session,\.model)) {
                ForEach(SaTReflowConfiguration.models,id:\.self) { Text($0).tag($0) }
            }.accessibilityIdentifier("sat-model")
                .disabled(session.localModels.sat.active)
            Button("下载／检查 SaT 模型与环境") { session.showSettings(.models) }
            DisclosureGroup("开发者：自定义 Python 环境") {
                Text("默认自动使用 App 管理的环境；只有使用自行安装的依赖时才修改此项。填写路径不会安装依赖。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("本地 Python 路径",text:Self.parameterBinding(session:session,\.pythonExecutable))
                    .accessibilityIdentifier("sat-python")
            }
            HStack {
                Text("换段阈值")
                Slider(value:Self.parameterBinding(session:session,\.paragraphThreshold),in:0.1...0.9,step:0.05)
                    .accessibilityIdentifier("sat-threshold")
                Text(session.config.captionReflow.sat.paragraphThreshold,format:.number.precision(.fractionLength(2))).monospacedDigit()
            }
            Text("建议阈值低于 0.50，默认 0.20。阈值越高，越难触发分段；不会因文字过长而强制切分。")
                .font(.caption).foregroundStyle(.secondary)
            if session.config.captionReflow.sat.paragraphThreshold > 0.5 {
                Text("警告：阈值超过 0.50，模型分数可能一直达不到要求，导致字幕持续不分段；后果自负。")
                    .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("sat-high-threshold-warning")
            }
            Stepper("最短段落：\(session.config.captionReflow.sat.minimumCharacters) 字符（双语合计）",value:Self.parameterBinding(session:session,\.minimumCharacters),in:20...2000,step:20)
                .accessibilityIdentifier("sat-minimum-characters")
            Text("临时文字先连续显示，定稿后在本机整理。双语仅在服务明确关联的语段之间换段；段落阈值越高，切得越少。").font(.caption).foregroundStyle(.secondary)
            Text(session.reflowStatus).font(.caption).foregroundStyle(.secondary)
        }
    }
}
