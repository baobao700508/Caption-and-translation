import Foundation
import LiveCaptionCore

@main struct ModelSetup {
    static func main() async {
        setbuf(stdout,nil)
        guard CommandLine.arguments.dropFirst().first == "whisper" else {
            print("用法：LiveCaptionModelSetup whisper [模型名]；SaT 使用 bash scripts/setup-sat.sh [模型名]")
            exit(64)
        }
        var config=LocalWhisperConfiguration()
        if CommandLine.arguments.count>2 { config.model=CommandLine.arguments[2] }
        do {
            try await LocalModelFiles.prepareWhisper(config) { fraction,message in
                let value:[String:Any]=["message":message,"progress":fraction as Any? ?? NSNull()]
                if let data=try? JSONSerialization.data(withJSONObject:value),let text=String(data:data,encoding:.utf8) { print(text) }
            }
            print("Whisper 已准备："+LocalModelFiles.whisperFolder(config).path)
        } catch { print("准备失败："+error.localizedDescription);exit(1) }
    }
}
