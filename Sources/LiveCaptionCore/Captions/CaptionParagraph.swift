import Foundation

/// A display group uses an explicit provider link, never the relative arrival order of two tracks.
public struct CaptionParagraph: Identifiable, Equatable, Sendable {
    public var id: String
    public var source: String
    public var translation: String
    public var unlinkedTranslation: Bool
    public var isFinal: Bool
    public var singleTrack: Bool
    public init(id:String,source:String,translation:String,unlinkedTranslation:Bool = false,isFinal:Bool = false,singleTrack:Bool = false) {
        self.id=id; self.source=source; self.translation=translation; self.unlinkedTranslation=unlinkedTranslation; self.isFinal=isFinal; self.singleTrack=singleTrack
    }
}

extension Transcript {
    public func captionParagraphs(epoch:Int) -> [CaptionParagraph] {
        var rows:[CaptionParagraph] = []
        var indices:[String:Int] = [:]
        var sourceReady:[String:Bool] = [:], translationReady:[String:Bool] = [:]
        // Source order is stable even if translated responses arrive out of order.
        for segment in segments where segment.epoch == epoch && segment.track == "source" {
            let key = "\(epoch):source:\(segment.providerID ?? segment.id)"
            indices[key] = rows.count
            sourceReady[key] = segment.finality == .final
            rows.append(CaptionParagraph(id:key,source:segment.text,translation:"",isFinal:segment.pipeline == .transcribe && segment.finality == .final,singleTrack:segment.pipeline == .transcribe))
        }
        for segment in segments where segment.epoch == epoch && segment.track == "translation" {
            let key = segment.sourceProviderID.map { "\(epoch):source:\($0)" } ?? "\(epoch):translation:\(segment.id)"
            if let index = indices[key] {
                translationReady[key] = (translationReady[key] ?? true) && segment.finality == .final
                if !rows[index].translation.isEmpty && !segment.text.isEmpty { rows[index].translation += "\n" }
                rows[index].translation += segment.text
            } else {
                indices[key] = rows.count
                rows.append(CaptionParagraph(id:key,source:"",translation:segment.text,unlinkedTranslation:segment.sourceProviderID == nil))
            }
        }
        for i in rows.indices where translationReady[rows[i].id] != nil {
            rows[i].isFinal = sourceReady[rows[i].id] == true && translationReady[rows[i].id] == true
        }
        return rows.filter { !$0.source.isEmpty || !$0.translation.isEmpty }
    }
}
