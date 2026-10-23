import Foundation
import SwiftParser
import SwiftSyntax

// 只忽略文件位置、import 和注释；保留声明中的所有运行语法 token。
func tokens(_ node:some SyntaxProtocol)->[String] {
    node.tokens(viewMode:.sourceAccurate).map { $0.text }
}
func snapshot(_ root:URL) throws -> [String:[[String]]] {
    var output:[String:[[String]]]=[:]
    let paths=FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil)!
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path<$1.path }
    for path in paths {
        let tree=Parser.parse(source:try String(contentsOf:path,encoding:.utf8))
        guard !tree.hasError else { throw NSError(domain:"源代码语法错误",code:1,userInfo:[NSLocalizedDescriptionKey:path.path]) }
        for item in tree.statements {
            guard let declaration=item.item.as(DeclSyntax.self),!declaration.is(ImportDeclSyntax.self) else { continue }
            if let node=declaration.as(ClassDeclSyntax.self),node.name.text == "AppSession" {
                let empty=node.memberBlock.with(\.members,MemberBlockItemListSyntax([]))
                output["AppSession.header",default:[]].append(tokens(node.with(\.memberBlock,empty)))
                for member in node.memberBlock.members { output["AppSession.members",default:[]].append(tokens(member.decl)) }
                // 属性初始化顺序保持不变，不能随方法分组一起重排。
                output["AppSession.propertyOrder",default:[]].append(node.memberBlock.members.filter { member in
                    guard let variable=member.decl.as(VariableDeclSyntax.self) else { return false }
                    return variable.bindings.contains { $0.initializer != nil || $0.accessorBlock == nil }
                }.flatMap { tokens($0.decl) })
            } else if let node=declaration.as(ExtensionDeclSyntax.self),node.extendedType.trimmedDescription == "AppSession" {
                guard node.attributes.isEmpty,node.modifiers.isEmpty,node.inheritanceClause == nil,node.genericWhereClause == nil else {
                    throw NSError(domain:"不支持修改 AppSession 扩展约束",code:2)
                }
                for member in node.memberBlock.members { output["AppSession.members",default:[]].append(tokens(member.decl)) }
            } else { output["declarations",default:[]].append(tokens(declaration)) }
        }
    }
    for key in Array(output.keys) { output[key]!.sort { $0.lexicographicallyPrecedes($1) } }
    return output
}
let arguments=CommandLine.arguments
let before=try snapshot(URL(fileURLWithPath:arguments[1]))
let after=try snapshot(URL(fileURLWithPath:arguments[2]))
let equal=before == after
let differences=Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.map { key in
    ["group":key,"removed":(before[key] ?? []).filter { !(after[key] ?? []).contains($0) }.prefix(4).map { Array($0.prefix(28)) },"added":(after[key] ?? []).filter { !(before[key] ?? []).contains($0) }.prefix(4).map { Array($0.prefix(28)) }] as [String:Any]
}
let result:[String:Any]=["success":equal,"declaration_count":before.values.reduce(0){$0+$1.count},
    "app_session_members":before["AppSession.members"]?.count ?? 0,
    "differences":differences,"changed_groups":Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted(),
    "scope":"所有 Sources Swift 声明的 token 与 AppSession 属性顺序；不将函数实现、常量或条件变化视为文件整理"]
print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
exit(equal ? 0:1)
