import Foundation

private var failures: [String] = []
func XCTAssertTrue(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { if !value() { failures.append("\(file):\(line): expected true") } }
func XCTAssertFalse(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { if value() { failures.append("\(file):\(line): expected false") } }
func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) { if lhs != rhs { failures.append("\(file):\(line): equality failed") } }
func XCTAssertEqual(_ lhs: Float, _ rhs: Float, accuracy: Float, file: StaticString = #filePath, line: UInt = #line) { if abs(lhs-rhs)>accuracy { failures.append("\(file):\(line): tolerance failed") } }
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value != nil { failures.append("\(file):\(line): expected nil") } }
func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value == nil { failures.append("\(file):\(line): expected non-nil") } }
func XCTAssertGreaterThan<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) { if !(lhs>rhs) { failures.append("\(file):\(line): expected greater") } }
func XCTAssertLessThan<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) { if !(lhs<rhs) { failures.append("\(file):\(line): expected less") } }

@main struct RunChecks {
    static func main() async {
        setbuf(stdout,nil)
        if CommandLine.arguments.count == 5,CommandLine.arguments[1] == "--sat-replay" {
            exit(await SaTReplayVerifier.run(fixtureURL:URL(fileURLWithPath:CommandLine.arguments[2]),
                root:URL(fileURLWithPath:CommandLine.arguments[3]),python:CommandLine.arguments[4]))
        }
        let checks = PipelineChecks()
        let cases: [(String, () async throws -> Void)] = [
            ("CPA只读本机client配置、不读钥匙串，拒绝发往远程地址", { try checks.testCPAUsesOnlyLocalClientConfiguration() }),
            ("AI关闭与重开不自动补，手动同时补正文和索引", { try await checks.testAIRecordDisabledReenableAndManualBackfill() }),
            ("AI失败重试去重，缺失与损坏索引只修复不重复调用", { try await checks.testAIRecordFailureRetryAndIndexOnlyRepair() }),
            ("AI索引写入失败后使用缓存摘要，不重复付费", { try await checks.testAIRecordProjectionFailureUsesCachedSummary() }),
            ("AI关闭并重开后拒绝旧任务的迟到结果", { try await checks.testAIRecordDisableInFlightRejectsLateResult() }),
            ("精简历史Markdown、正文hash与长记录分块完整性", { try checks.testAIRecordCompactLegacyAndLongInput() }),
            ("本地模型未完成下载不能标记可用，自定义环境保留", { try checks.testModelReadinessRejectsIncompleteDownloads() }),
            ("取消SaT环境准备会终止安装进程，不能继续发布完成标记", { try await checks.testSaTPreparationCancellationStopsWorker() }),
            ("旧JEV与聊天配置迁移SaT，删除整理云端地址和凭据字段", { try checks.testSaTOnlyMigrationDropsCloudConfiguration() }),
            ("关闭SaT原样保留VAD三段与乱序中英关联，取消排队及迟到结果", { try await checks.testSaTOffPreservesVADGroupsAndCancelsWork() }),
            ("Speaker 编号0保留、同人复用、关联译文继承及VAD不编造编号", { try await checks.testBailianSpeakerIdentityIsPreserved() }),
            ("连接中途检测配置变化须记录并拒绝，不静默回退", { try await checks.testBailianLaterDetectorChangeCannotSilentlyFallback() }),
            ("SaT 审计失败不推理、配置失败仍显示及关闭", { try await checks.testSaTAuditFailureInvalidConfigurationAndDisabled() }),
            ("SaT 本地概率、显式双语关联与配置兼容", { try await checks.testSaTLocalSelectionAndExplicitBilingualLinks() }),
            ("SaT 四条路径 draft/final、迟到译文与定稿修订", { try await checks.testSaTAllFourRoutesDraftFinalAndRevision() }),
            ("SaT 过期代次隔离与失败保留全文", { try await checks.testSaTStaleEpochAndFailureRetainAllText() }),
            ("SaT 实际本地模型与 Unicode 保真（显式启用）", { try await checks.testSaTRealLocalRuntimeWhenRequested() }),
            ("译音动态追赶双水位、速度边界、清空及关闭", { try checks.testCatchUpHysteresisBoundsAndReset() }),
            ("十五分钟中文持续多20%仍保持有界、停顿排空且不丢音", { checks.testCatchUpSustainedTranslationSurplusDoesNotGrowUnbounded() }),
            ("百炼可选WebSocket及追赶配置兼容，非法参数拒绝", { try checks.testTransportAndPartialCatchUpConfiguration() }),
            ("仅文字禁止连接Google译音线路，语音同传与原文转写保留", { try await checks.testTextOnlyNeverOpensGoogleAudioTranslation() }),
            ("Whisper 模型内部半句边界不能固定为最终字幕", { try checks.testWhisperDoesNotFreezeHalfAPhraseAtAModelSegment() }),
            ("本地 Whisper 无云密钥、无定时重连、Google 旧配置兼容", { try checks.testWhisperRoutingDoesNotRequireCloudKeyOrRotate() }),
            ("Whisper 选择持久化、不能误作翻译供应商", { try checks.testWhisperConfigurationRoundTripAndInvalidMode() }),
            ("百炼课堂不按九分钟强制轮换，Google既有策略独立", { checks.testClassroomConnectionRotationPolicy() }),
            ("译音连续时间轴保留静音、实际回调时间和连接边界", { try checks.testDecodedTimelinePreservesSilenceAndCallbackTimes() }),
            ("Google 停止后收到末段定稿必须完成收尾", { try await checks.testGoogleFlushAcceptsFinalAfterEnd() }),
            ("Google 定稿后的静音包不能造成尾段未确认误报", { try await checks.testGoogleFinalBeforeTrailingSilenceDoesNotBecomeIncomplete() }),
            ("Google 旧定稿和turnComplete不能掩盖新一段未定稿文字", { try await checks.testGoogleOldFinalCannotHideLaterUnfinishedSpeech() }),
            ("Google 取消收尾不能把旧定稿误报为完成", { try await checks.testGoogleCancellationCannotConfirmOldFinal() }),
            ("Google 没有识别结果或连接失败不能被旧定稿判为完成", { try await checks.testGoogleMissingResultOrFailureCannotConfirm() }),
            ("Google 正式末段晚于两秒仍须等待并正确收尾", { try await checks.testGoogleWaitsForDelayedFinal() }),
            ("Google 仅临时结果不可冒充收尾，结束后拒绝新音频", { try await checks.testGoogleFlushRejectsInterimTimeout() }),
            ("断线3.5秒旧音频丢弃，恢复只消费新音频", { checks.testReconnectQueueDropsOldFramesAndKeepsFuture() }),
            ("发送阻塞导致队列溢出时，丢弃样本精确记账且不另存音频", { checks.testOverflowIsCountedWithoutRetainingAudio() }),
            ("重排逐字节保真、Unicode、错误切点拒绝与配置兼容", { try checks.testReflowLosslessAndRejectedPlans() }),
            ("保留原译文定稿标记与纯转写标记", { checks.testReflowWaitsForBothFinalTracks() }),
            ("仅最终译文事件仍保留原文关联", { try checks.testFinalOnlyTranslationRetainsSourceLink() }),
            ("双语逐段关联、乱序译文、最终修订和连接隔离", { checks.testCaptionParagraphsPairByIdentityAndKeepRevisions() }),
            ("原文迟到合并、无关联译文独立保留", { checks.testCaptionLateSourceAndUnlinkedTranslation() }),
            ("拒绝错误目标语种、模态和输入格式回显", { try checks.testBailianConfirmsRequestedSession() }),
            ("原译文关联与服务端音频时间轴", { try checks.testBailianSourceAssociationAndAudioClock() }),
            ("1.5秒发送完成等待不得持续丢失实时音频", { try checks.testSenderCatchesUpAfterOnePointFiveSecondWrites() }),
            ("100ms麦克风回调不得提前填静音吞掉人声", { try checks.testDelayedMicrophoneCallbacksDoNotInventSilence() }),
            ("慢发送合并积压音频、无额外等待与逐字节完整性", { try checks.testSlowSenderCoalescesWithoutWaitingOrLosingPCM() }),
            ("上传录音逐字节一致、失败排除、连接归属与运行中WAV回读", { try await checks.testArchivedConnectionExactPCMAndEpochs() }),
            ("百炼地区、鉴权隔离与旧配置兼容", { try checks.testBailianConfiguration() }),
            ("百炼交错分段、重复事件和最终修订", { try checks.testBailianInterleavedText() }),
            ("百炼译音、打断与协议版本保护", { try checks.testBailianAudioAndInterruptedResponse() }),
            ("百炼握手、实时发送和确认后收尾（模拟传输）", { try await checks.testBailianLifecycle() }),
            ("重复握手不重复更新会话", { try await checks.testBailianDuplicateGreeting() }),
            ("服务器完成后的译音排空与普通收尾超时分开", { try await checks.testBailianNativePlayoutDeadline() }),
            ("百炼握手和收尾超时、凭据脱敏（模拟传输）", { try await checks.testBailianFailureAndTimeout() }),
            ("百炼运行中日志与崩溃恢复", { try await checks.testBailianLiveLogAndRecovery() }),
            ("崩溃日志恢复、残行保全和活动进程保护", { try await checks.testCrashRecoveryPreservesPartialFragmentAndCorrectedText() }),
            ("独立模型配置", { try checks.testIndependentModelsHaveDifferentSetupContracts() }),
            ("临时修订和定稿去重", { try checks.testInterimCorrectionFinalAndNewUtteranceDoNotDuplicate() }),
            ("中断末段未确认标记", { checks.testInterruptedHypothesisRemainsExplicitlyUnconfirmed() }),
            ("译文、原文与真实PCM负载解析", { try checks.testTranslateAudioAndIndependentTextTracks() }),
            ("课堂运行中真实文件追读", { try await checks.testOngoingClassReadableBeforeFinalAndAfterCorrection() }),
            ("跨线路迟到结果归属", { try await checks.testRouteSwitchPreservesOneSessionAndLateOldMetadata() }),
            ("音频环形缓冲和反相保护", { try checks.testRingHandlesStereoAntiPhaseWithoutLosingSpeech() }),
            ("实际WebRTC降噪处理", { try checks.testEmbeddedNoiseSuppressorReallyProcessesFiniteAudio() })
        ]
        for (name, work) in cases {
            let before = failures.count
            do { try await work() } catch { failures.append("\(name): \(error.localizedDescription)") }
            print("\(failures.count == before ? "PASS" : "FAIL") \(name)")
        }
        for failure in failures { print(failure) }
        print("\(cases.count) checks, \(failures.count) failures")
        exit(failures.isEmpty ? 0 : 1)
    }
}
