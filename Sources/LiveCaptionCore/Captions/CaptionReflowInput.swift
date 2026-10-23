import Foundation

public struct CaptionReflowInput:Sendable {
    public let source:[String]
    public let translation:[String]
    public let providerBoundaries:[[Int]]
    public init(source:String,translation:String,providerBoundaries:[[Int]] = []) {
        self.source=Self.atoms(source);self.translation=Self.atoms(translation)
        self.providerBoundaries=providerBoundaries
    }
    private static func atoms(_ text:String) -> [String] {
        var result:[String] = [],word="",opening="",doubleQuoteOpen=false
        func flush() { if !word.isEmpty { result.append(opening+word); opening="";word="" } }
        // Iterating Character (not regex scalar offsets) keeps combining marks and emoji intact.
        for character in text {
            let part=String(character)
            let opens=["(","[","{","（","【","《","〈","「","『","“","‘"].contains(part) || (part == "\"" && !doubleQuoteOpen)
            if part == "\"" { doubleQuoteOpen.toggle() }
            if opens { flush();opening += part;continue }
            let wordCharacter=part.unicodeScalars.allSatisfy {
                $0.value < 0x2E80 && (CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0))
            }
            if wordCharacter || (!word.isEmpty && ["'","’","-"].contains(part)) { word += part; continue }
            flush()
            if !opening.isEmpty {
                if part.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) { opening += part }
                else { result.append(opening+part);opening="" }
            } else if !result.isEmpty && part.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.punctuationCharacters.contains($0) }) {
                result[result.count-1] += part
            } else { result.append(part) }
        }
        flush()
        if !opening.isEmpty { result.append(opening) }
        return result
    }
    public func render(_ response:String, id:String) throws -> [CaptionParagraph] {
        // Accept code fences without imposing a server response_format or tool schema.
        guard response.utf8.count <= 65536, let start = response.firstIndex(of:"{"), let end = response.lastIndex(of:"}"), start <= end else {
            throw CaptionError.message("重排结果没有可读取的分组")
        }
        struct Plan: Decodable { let groups:[[Int]] }
        let plan = try JSONDecoder().decode(Plan.self,from:Data(response[start...end].utf8))
        guard !plan.groups.isEmpty, plan.groups.count <= 64 else { throw CaptionError.message("重排分组数量无效") }
        var s = 0, t = 0, rows:[CaptionParagraph] = []
        for (i,pair) in plan.groups.enumerated() {
            guard pair.count == 2 else { throw CaptionError.message("重排切点格式无效") }
            let se = pair[0], te = pair[1]
            guard (source.isEmpty ? se == 0 : se > s && se <= source.count),
                  (translation.isEmpty ? te == 0 : te > t && te <= translation.count) else {
                throw CaptionError.message("重排切点越界、重复或乱序")
            }
            rows.append(CaptionParagraph(id:"\(id):\(i)",source:source[s..<se].joined(),translation:translation[t..<te].joined(),isFinal:true))
            s = se; t = te
        }
        guard s == source.count, t == translation.count,
              Array(rows.map(\.source).joined().utf8) == Array(source.joined().utf8),
              Array(rows.map(\.translation).joined().utf8) == Array(translation.joined().utf8) else {
            throw CaptionError.message("重排未完整保留原文与译文")
        }
        return rows
    }
}
