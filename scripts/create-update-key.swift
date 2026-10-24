import Foundation
import CryptoKit

// 私钥只保存在本机发布目录，不访问钥匙串，也不进入应用包或 Git。
let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveCaptionRelease",isDirectory:true)
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
let file=directory.appendingPathComponent("ed25519.key")
let key:Curve25519.Signing.PrivateKey
if FileManager.default.fileExists(atPath:file.path) {
    let text=try String(contentsOf:file,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
    guard let data=Data(base64Encoded:text) else { fatalError("更新私钥格式无效，未覆盖现有文件。") }
    key=try Curve25519.Signing.PrivateKey(rawRepresentation:data)
} else {
    key=Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.base64EncodedString().write(to:file,atomically:true,encoding:.utf8)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
