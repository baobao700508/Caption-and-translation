import Foundation
import LiveCaptionCore

/// File writes cannot finish out of order and restore an earlier enabled state.
actor CaptionReflowSettingsWriter {
    private var latestRevision:UInt64=0
    func save(_ value:CaptionReflowConfiguration,revision:UInt64,url:URL) throws -> Date? {
        guard revision >= latestRevision else { return nil }
        latestRevision=revision
        let scoped=url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard var document=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any] else {
            throw CaptionError.message("配置文件格式无效")
        }
        document["captionReflow"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))
        try JSONSerialization.data(withJSONObject:document,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        return (try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? Date()
    }
}
