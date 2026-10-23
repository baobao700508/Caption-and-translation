import Foundation

/// Disabling SaT projects the original provider-linked segments without merging or splitting.
@MainActor public final class CaptionReflowCoordinator {
    public typealias Complete = @Sendable (CaptionReflowInput,CaptionReflowConfiguration) async throws -> String
    public var onChange:(([CaptionParagraph],String)->Void)?
    public var onApplied:(([String],[CaptionParagraph],Double)->Void)?
    public var onTrace:CaptionReflowTrace.Sink?
    public private(set) var rows:[CaptionParagraph]=[]
    public private(set) var status="未启用"
    public private(set) var pending=false
    public private(set) var attemptCount=0
    private var sat:SaTReflowCoordinator?
    private let debounce:TimeInterval
    private let complete:Complete?
    private var audits:[UUID:Task<Void,Never>]=[:]
    private var providerSignature:[CaptionParagraph]=[]
    private var providerContext=""
    public init(partialInterval:TimeInterval=0,debounce:TimeInterval=0.4,minimumInterval:TimeInterval=0,complete:Complete?=nil) {
        self.debounce=debounce;self.complete=complete
    }
    public func cancel() {
        if pending,let trace=onTrace { audit(trace,"caption.reflow.discarded",["reason":"disabled_configuration_changed_or_stop"]) }
        sat?.reset();sat=nil;pending=false
    }
    public func reset() {
        cancel();rows=[];status="未启用";attemptCount=0;providerSignature=[];providerContext=""
    }
    public func update(_ incoming:[CaptionParagraph],configuration:CaptionReflowConfiguration,context:String) {
        guard configuration.enabled else {
            cancel();rows=incoming;status="未启用 · 按服务器语段显示"
            onChange?(rows,status)
            if providerSignature != incoming || providerContext != context {
                providerSignature=incoming;providerContext=context
                if let trace=onTrace { audit(trace,"caption.presentation.changed",[
                    "context":context,"display_policy":"provider_groups","provider_group_ids":incoming.map(\.id),
                    "row_ids":incoming.map(\.id),"provider_group_count":incoming.count,"display_row_count":incoming.count,"byte_identical":true]) }
            }
            return
        }
        if sat == nil {
            let coordinator=SaTReflowCoordinator(debounce:debounce,complete:complete)
            coordinator.onChange={ [weak self,weak coordinator] rows,status,pending in
                guard let self,let coordinator else { return }
                self.rows=rows;self.status=rows.isEmpty ? "SaT 已开启，等待文字":status
                self.pending=pending;self.attemptCount=coordinator.attemptCount
                self.onChange?(rows,self.status)
            }
            coordinator.onApplied={ [weak self] ids,rows,seconds in self?.onApplied?(ids,rows,seconds) }
            sat=coordinator
        }
        sat?.onTrace=onTrace
        sat?.update(incoming,configuration:configuration,context:context)
    }
    public func finish(timeout:TimeInterval=20) async {
        await sat?.finish(timeout:timeout)
        for task in Array(audits.values) { await task.value }
    }
    private func audit(_ sink:@escaping CaptionReflowTrace.Sink,_ event:String,_ fields:[String:Any]) {
        guard let trace=try? CaptionReflowTrace(event,fields) else { return }
        let id=UUID()
        audits[id]=Task { [weak self] in
            do { try await sink(trace) }
            catch { self?.status="分段行为日志写入失败，保留字幕" }
            self?.audits.removeValue(forKey:id)
        }
    }
}
