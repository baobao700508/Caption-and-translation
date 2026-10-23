import Foundation

/// SaT consumes final text only. Draft text stays visible in one open paragraph.
/// Semantic cuts are separate from the provider-linked units used to bound local inference.
@MainActor final class SaTReflowCoordinator {
    struct Snapshot:Equatable { let source:String; let translation:String }
    struct Unit { let sourceEnd:Int; let translationEnd:Int; let id:String }
    struct Job {
        let snapshot:Snapshot; let input:CaptionReflowInput
        let sourceStart:Int; let translationStart:Int; let sourceEnd:Int; let translationEnd:Int
        let ids:[String]
    }
    var onChange:(([CaptionParagraph],String,Bool)->Void)?
    var onApplied:(([String],[CaptionParagraph],Double)->Void)?
    var onTrace:CaptionReflowTrace.Sink?
    private var raw:[CaptionParagraph]=[]
    private var fixed:[CaptionParagraph]=[]
    private var scanned=Snapshot(source:"",translation:"")
    private var configuration=CaptionReflowConfiguration()
    private var context=""
    private var generation=UUID()
    private var scheduled:Task<Void,Never>?
    private var task:Task<Void,Never>?
    private var failedSnapshot:Snapshot?
    private let complete:CaptionReflowCoordinator.Complete?
    private let debounce:TimeInterval
    private(set) var attemptCount=0
    private(set) var pending=false
    private var status="未启用"
    private var signature:[String]=[]
    private var audits:[UUID:Task<Void,Never>]=[:]
    init(debounce:TimeInterval,complete:CaptionReflowCoordinator.Complete?) { self.debounce=debounce;self.complete=complete }
    func reset() {
        scheduled?.cancel();task?.cancel();scheduled=nil;task=nil;generation=UUID();pending=false
        raw=[];fixed=[];scanned=Snapshot(source:"",translation:"");failedSnapshot=nil;context="";signature=[];attemptCount=0
    }
    private var prefixRows:[CaptionParagraph] { Array(raw.prefix { !$0.unlinkedTranslation }) }
    private var current:Snapshot { Snapshot(source:prefixRows.map(\.source).joined(),translation:prefixRows.map(\.translation).joined()) }
    private var finalized:[CaptionParagraph] {
        Array(prefixRows.prefix { $0.isFinal && ($0.singleTrack || (!$0.source.isEmpty && !$0.translation.isEmpty)) })
    }
    private var finalText:Snapshot { Snapshot(source:finalized.map(\.source).joined(),translation:finalized.map(\.translation).joined()) }
    func update(_ rows:[CaptionParagraph],configuration c:CaptionReflowConfiguration,context key:String) {
        if c != configuration || key != context { reset();configuration=c;context=key }
        let previousFinal=finalText
        raw=rows
        if previousFinal != finalText { failedSnapshot=nil }
        let text=current
        let sourceBytes=Array(text.source.utf8),translationBytes=Array(text.translation.utf8)
        var s=0,t=0,keep=0
        for row in fixed {
            let se=s+row.source.utf8.count,te=t+row.translation.utf8.count
            guard se<=sourceBytes.count,te<=translationBytes.count,
                  sourceBytes[s..<se].elementsEqual(row.source.utf8),translationBytes[t..<te].elementsEqual(row.translation.utf8) else { break }
            keep += 1;s=se;t=te
        }
        if keep<fixed.count {
            let rejected=fixed.count-keep;fixed=Array(fixed.prefix(keep))
            log("caption.sat.revision",["invalidated_paragraphs":rejected,"retained_paragraphs":keep,"reason":"final_text_revised"])
        }
        let final=finalText
        if !final.source.utf8.starts(with:scanned.source.utf8) || !final.translation.utf8.starts(with:scanned.translation.utf8) {
            scanned=Snapshot(source:fixed.map(\.source).joined(),translation:fixed.map(\.translation).joined())
            failedSnapshot=nil
        }
        publish()
        do { try c.sat.validate() }
        catch { status=error.localizedDescription;publish();return }
        schedule()
    }
    private func schedule() {
        guard task == nil,scheduled == nil,let job=nextJob(),job.snapshot != failedSnapshot else { return }
        pending=true;status="等待定稿段落整理，文字已显示";publish()
        let token=generation
        scheduled=Task { [weak self] in
            if let wait=self?.debounce,wait>0 { do { try await Task.sleep(nanoseconds:UInt64(wait*1e9)) } catch { return } }
            guard let self,self.generation == token,!Task.isCancelled else { return }
            self.scheduled=nil
            guard let latest=self.nextJob(),latest.snapshot != self.failedSnapshot else { self.pending=false;self.publish();return }
            self.launch(latest)
        }
    }
    private func nextJob()->Job? {
        let rows=finalized,text=finalText
        guard !rows.isEmpty,text != scanned else { return nil }
        var units:[Unit]=[],s=0,t=0
        for row in rows {
            if row.singleTrack {
                let atoms=CaptionReflowInput(source:row.source,translation:"").source
                var count=0
                for atom in atoms {
                    s += atom.utf8.count;count += atom.count
                    if count>=1600 { units.append(Unit(sourceEnd:s,translationEnd:t,id:row.id));count=0 }
                }
                if units.last?.sourceEnd != s { units.append(Unit(sourceEnd:s,translationEnd:t,id:row.id)) }
            } else {
                s += row.source.utf8.count;t += row.translation.utf8.count
                units.append(Unit(sourceEnd:s,translationEnd:t,id:row.id))
            }
        }
        guard let next=units.firstIndex(where:{$0.sourceEnd>scanned.source.utf8.count || $0.translationEnd>scanned.translation.utf8.count}) else { return nil }
        var begin=max(0,next-2),end=next
        // At most ~10k characters of context, never the complete hour-long transcript.
        func size(_ a:Int,_ b:Int)->Int {
            let left=a>0 ? units[a-1]:Unit(sourceEnd:0,translationEnd:0,id:"")
            return (slice(text.source,left.sourceEnd,units[b].sourceEnd)?.count ?? 0)+(slice(text.translation,left.translationEnd,units[b].translationEnd)?.count ?? 0)
        }
        while begin<next && size(begin,next)>10000 { begin += 1 }
        while end+1<units.count && size(begin,end+1)<=10000 { end += 1 }
        let left=begin>0 ? units[begin-1]:Unit(sourceEnd:0,translationEnd:0,id:"")
        guard let source=slice(text.source,left.sourceEnd,units[end].sourceEnd),
              let translation=slice(text.translation,left.translationEnd,units[end].translationEnd) else { return nil }
        let base=CaptionReflowInput(source:source,translation:translation)
        func offsets(_ atoms:[String])->[Int:Int] {
            var total=0,result:[Int:Int]=[0:0]
            for (i,atom) in atoms.enumerated() { total += atom.utf8.count;result[total]=i+1 };return result
        }
        let se=offsets(base.source),te=offsets(base.translation)
        let boundaries=units[begin...end].compactMap { unit -> [Int]? in
            guard let a=se[unit.sourceEnd-left.sourceEnd],let b=te[unit.translationEnd-left.translationEnd] else { return nil }
            return [a,b]
        }
        return Job(snapshot:Snapshot(source:String(decoding:text.source.utf8.prefix(units[end].sourceEnd),as:UTF8.self),
                                     translation:String(decoding:text.translation.utf8.prefix(units[end].translationEnd),as:UTF8.self)),
            input:CaptionReflowInput(source:source,translation:translation,providerBoundaries:boundaries),
            sourceStart:left.sourceEnd,translationStart:left.translationEnd,sourceEnd:units[end].sourceEnd,translationEnd:units[end].translationEnd,
            ids:Array(Set(units[begin...end].map(\.id))).sorted())
    }
    private func launch(_ job:Job) {
        let token=generation,c=configuration,observer=onTrace,key=context,id=UUID().uuidString,complete=self.complete
        attemptCount += 1
        pending=true;status="SaT 本地整理中，文字已显示";publish()
        let trace:CaptionReflowTrace.Sink = { event in
            try await observer?(CaptionReflowTrace(event.event,event.fields.merging(["job_id":id,"context":key,
                "provider_group_ids":job.ids,"engine":"sat"]) { _,new in new }))
        }
        task=Task { [weak self] in
            let start=Date()
            do {
                try await trace(CaptionReflowTrace("caption.reflow.started",["trigger_reason":"provider_final_text",
                    "source_window_start_bytes":job.sourceStart,"source_window_end_bytes":job.sourceEnd,
                    "translation_window_start_bytes":job.translationStart,"translation_window_end_bytes":job.translationEnd,
                    "model":c.sat.model,"input_policy":"draft_visible_final_segmented"]))
                let result:String
                if let complete { result=try await complete(job.input,c) }
                else { result=try await SaTCaptionReflow.complete(job.input,configuration:c.sat,trace:trace) }
                try Task.checkCancellation()
                let output=try job.input.render(result,id:"sat-\(id)")
                guard let self,self.generation == token else { return }
                let final=self.finalText
                guard final.source.utf8.starts(with:job.snapshot.source.utf8),final.translation.utf8.starts(with:job.snapshot.translation.utf8) else {
                    try await trace(CaptionReflowTrace("caption.reflow.discarded",["reason":"final_revision_during_sat_inference"]))
                    self.task=nil;self.pending=false;self.publish();self.schedule();return
                }
                var proposed=self.fixed
                var se=job.sourceStart,te=job.translationStart
                for row in output.dropLast() {
                    se += row.source.utf8.count;te += row.translation.utf8.count
                    let fs=proposed.reduce(0){$0+$1.source.utf8.count},ft=proposed.reduce(0){$0+$1.translation.utf8.count}
                    guard (final.source.isEmpty ? se == 0:se>fs),(final.translation.isEmpty ? te == 0:te>ft),
                          let source=self.slice(final.source,fs,se),let translation=self.slice(final.translation,ft,te) else { continue }
                    proposed.append(CaptionParagraph(id:row.id,source:source,translation:translation,isFinal:true,singleTrack:job.input.translation.isEmpty))
                }
                try await trace(CaptionReflowTrace("caption.reflow.validated",["byte_identical":true,"fixed_paragraphs":proposed.count,
                    "elapsed_seconds":Date().timeIntervalSince(start)]))
                guard self.generation == token,!Task.isCancelled else { return }
                let latest=self.finalText
                guard latest.source.utf8.starts(with:job.snapshot.source.utf8),latest.translation.utf8.starts(with:job.snapshot.translation.utf8) else {
                    self.task=nil;self.pending=false;self.publish();self.schedule();return
                }
                self.fixed=proposed;self.scanned=job.snapshot;self.failedSnapshot=nil;self.task=nil;self.pending=false
                self.status=proposed.isEmpty ? "SaT 已检查，等待合适段界":"已整理 · SaT \(c.sat.model)";self.publish()
                self.onApplied?(job.ids,self.projection(),Date().timeIntervalSince(start));self.schedule()
            } catch {
                guard let self,self.generation == token,!Task.isCancelled else { return }
                self.task=nil;self.pending=false;self.failedSnapshot=job.snapshot
                self.status=(error is CaptionError ? error.localizedDescription:"SaT 未完成整理；请检查本地环境")+"；完整文字已保留"
                try? await trace(CaptionReflowTrace("caption.reflow.failed",["reason":"sat_local_request_or_validation_failed",
                    "message":error is CaptionError ? error.localizedDescription:"SaT 本地响应未通过校验"]))
                self.publish()
            }
        }
    }
    private func projection()->[CaptionParagraph] {
        let text=current,s=fixed.reduce(0){$0+$1.source.utf8.count},t=fixed.reduce(0){$0+$1.translation.utf8.count}
        var result=fixed
        let source=slice(text.source,s,text.source.utf8.count) ?? text.source
        let translation=slice(text.translation,t,text.translation.utf8.count) ?? text.translation
        if !source.isEmpty || !translation.isEmpty {
            result.append(CaptionParagraph(id:"sat-pending-\(context)",source:source,translation:translation,singleTrack:prefixRows.allSatisfy(\.singleTrack)))
        }
        // An unlinked translation remains explicit. Never pair it by arrival order.
        result += raw.dropFirst(prefixRows.count)
        return result
    }
    private func publish() {
        let rows=projection();onChange?(rows,status,pending)
        let ids=rows.map(\.id)+raw.map(\.id)
        if ids != signature {
            signature=ids
            log("caption.presentation.changed",["display_policy":"sat_final_paragraphs_open_draft",
                "provider_group_ids":raw.map(\.id),"provider_group_count":raw.count,"row_ids":rows.map(\.id),
                "display_row_count":rows.count,"byte_identical":rows.map(\.source).joined().utf8.elementsEqual(raw.map(\.source).joined().utf8)
                    && rows.map(\.translation).joined().utf8.elementsEqual(raw.map(\.translation).joined().utf8)])
        }
    }
    private func log(_ event:String,_ fields:[String:Any]) {
        let observer=onTrace,key=context,id=UUID()
        audits[id]=Task { [weak self] in
            try? await observer?(CaptionReflowTrace(event,fields.merging(["context":key,"engine":"sat"]) { _,new in new }))
            self?.audits.removeValue(forKey:id)
        }
    }
    private func slice(_ text:String,_ a:Int,_ b:Int)->String? {
        guard a>=0,b>=a,b<=text.utf8.count else { return nil }
        return String(bytes:text.utf8.dropFirst(a).prefix(b-a),encoding:.utf8)
    }
    func finish(timeout:TimeInterval) async {
        let start=Date();schedule()
        while pending && Date().timeIntervalSince(start)<timeout {
            do { try await Task.sleep(nanoseconds:20_000_000) } catch { break }
        }
        if pending { scheduled?.cancel();task?.cancel();scheduled=nil;task=nil;generation=UUID();pending=false
            log("caption.reflow.discarded",["reason":"sat_stop_deadline"]);publish() }
        for audit in Array(audits.values) { await audit.value }
    }
}
