import SwiftUI
import LiveCaptionCore

struct AIRecordSettings:View {
    @ObservedObject var controller:AIRecordController
    let root:URL
    var body:some View {
        Section("AI 友好设置") {
            Toggle("生成 AI 标题、摘要与索引",isOn:$controller.settings.enabled)
                .accessibilityIdentifier("ai-record-enabled")
            Text("开启后，为新会话在结束时生成标题和简短摘要，并更新日志根目录的 index.md。关闭后不调用模型，也不更新 AI 索引。")
                .font(.caption).foregroundStyle(.secondary)
            Group {
                TextField("AI Provider",text:$controller.settings.provider,prompt:Text("如 CPA；使用 Chat Completions 兼容接口"))
                    .accessibilityIdentifier("ai-record-provider")
                TextField("API 地址",text:$controller.settings.baseURL,prompt:Text("服务商提供的 Base URL，通常以 /v1 结尾"))
                    .accessibilityIdentifier("ai-record-url")
                Toggle("使用本机 CPA 配置中的 Key",isOn:$controller.settings.useLocalCPA)
                    .accessibilityIdentifier("ai-record-local-cpa")
                SecureField("API Key",text:$controller.apiKey,prompt:Text(controller.settings.useLocalCPA ? "使用 CPA 本机配置，不读写钥匙串" : "单独保存在 macOS 钥匙串"))
                    .disabled(controller.settings.useLocalCPA)
                    .accessibilityIdentifier("ai-record-key")
                TextField("摘要模型",text:$controller.settings.model,prompt:Text("填写服务商提供的轻量快速模型 ID"))
                    .accessibilityIdentifier("ai-record-model")
            }.disabled(!controller.settings.enabled || controller.working)
            Text("配置自动保存。CPA 本机模式直接读取现有配置，不读写钥匙串；手动填写的 Key 按 API 地址分别保存在钥匙串，不与语音服务混用。转写文字会发给所选 Provider，录音不发送；摘要不阻塞录音或翻译，长记录分段概括后合并。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("测试连接",action:controller.testConnection).accessibilityIdentifier("ai-record-test")
                Button(controller.inspecting ? "正在检查历史…" : "补齐历史摘要与索引…",action:controller.inspectHistory)
                    .accessibilityIdentifier("ai-record-backfill")
            }.disabled(!controller.settings.enabled || controller.working || controller.inspecting)
            Text("重新开启不会自动补齐历史记录。请点击“补齐历史摘要与索引…”手动补齐记录中的标题、摘要和 index.md；已有摘要只修复索引，不重复调用模型。")
                .font(.caption).foregroundStyle(.secondary)
            if controller.working || controller.inspecting { ProgressView().controlSize(.small) }
            Text(controller.message).font(.caption).textSelection(.enabled).accessibilityIdentifier("ai-record-status")
        }
        .onAppear { controller.setRoot(root) }
        .onChange(of:root) { _,value in controller.setRoot(value) }
        .sheet(isPresented:$controller.showPlan,onDismiss:controller.cancelPlan) {
            VStack(alignment:.leading,spacing:16) {
                Text("补齐历史摘要与索引").font(.headline)
                Text("需要调用 AI：\(controller.modelCount) 条\n只需修复记录或索引：\(controller.repairCount) 条")
                Text(controller.plan.isEmpty ? "没有需要补齐的记录。正在录制或没有文字的记录不参与。" : "同时补齐会话 Markdown 与根目录 index.md。已完成项会跳过，失败项可再次点击重试。调用 AI 将向所配置 Provider 发送对应的转写文字。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消",role:.cancel,action:controller.cancelPlan)
                    Button("开始补齐",action:controller.runPlan).buttonStyle(.borderedProminent)
                        .disabled(controller.plan.isEmpty).accessibilityIdentifier("ai-record-confirm-backfill")
                }
            }.padding(24).frame(width:440)
        }
    }
}
