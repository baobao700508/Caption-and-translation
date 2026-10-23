#import "WebRTCBridge.h"
#import "RTCAudioDevice.h"
#import <WebRTC/WebRTC.h>
#include <atomic>
#include <chrono>
#include <deque>
#include <mutex>
#include <thread>

// This device never opens a microphone or speaker. Its only input is the existing PCM pipeline.
@interface LCRTCDevice : NSObject <RTCAudioDevice> {
    std::atomic<bool> _stop, _recording, _playing, _tail;
    std::atomic<int64_t> _lastAudibleMs;
    std::thread _clock;
    std::mutex _mutex;
    std::deque<int16_t> _pcm;
    bool _started, _timelineProbe;
    uint64_t _consumed, _underflow, _padding, _outputHangover;
}
@property(nonatomic,strong) id<RTCAudioDeviceDelegate> delegate;
@property(nonatomic,copy) void (^output)(const void *,size_t);
@property(nonatomic,copy) void (^input)(const void *,size_t);
@property(nonatomic,copy) void (^probeOutput)(const void *,size_t);
@property(nonatomic,copy) void (^diagnostic)(NSDictionary *);
@property(nonatomic,assign) BOOL isInitialized, isPlayoutInitialized, isRecordingInitialized;
- (int)push:(const void *)bytes length:(size_t)length;
- (int)pending;
- (void)finishInput;
- (void)report;
- (int64_t)outputIdleMs;
@end
@implementation LCRTCDevice
- (void)dealloc {
    _stop=true;
    if(_clock.joinable()) { if(_clock.get_id()==std::this_thread::get_id())_clock.detach(); else _clock.join(); }
}
- (double)deviceInputSampleRate { return 16000; }
- (double)deviceOutputSampleRate { return 24000; }
- (NSInteger)inputNumberOfChannels { return 1; }
- (NSInteger)outputNumberOfChannels { return 1; }
- (NSTimeInterval)inputIOBufferDuration { return .01; }
- (NSTimeInterval)outputIOBufferDuration { return .01; }
- (NSTimeInterval)inputLatency { return .2; }
- (NSTimeInterval)outputLatency { return .01; }
- (BOOL)isRecording { return _recording; }
- (BOOL)isPlaying { return _playing; }
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    self.delegate = delegate; self.isInitialized = YES; _stop = false;
    _timelineProbe = [NSProcessInfo.processInfo.environment[@"LIVECAPTION_AUDIO_TIMELINE_PROBE"] isEqual:@"1"];
    __weak LCRTCDevice *weak = self;
    _clock = std::thread([weak] {
        auto next = std::chrono::steady_clock::now(); uint64_t tick = 0;
        while (true) {
            next += std::chrono::milliseconds(10); std::this_thread::sleep_until(next);
            @autoreleasepool {
                LCRTCDevice *device = weak; if (!device || device->_stop) break;
                id<RTCAudioDeviceDelegate> delegate = device.delegate; if (!delegate) continue;
                AudioTimeStamp stamp = {}; stamp.mFlags = kAudioTimeStampSampleTimeValid;
                AudioUnitRenderActionFlags flags = 0;
                if (device->_recording) {
                    int16_t samples[160] = {}; size_t consumed = 0;
                    { std::lock_guard<std::mutex> lock(device->_mutex);
                        if (!device->_started && (device->_pcm.size() >= 3200 || (device->_tail && !device->_pcm.empty()))) device->_started = true;
                        if (device->_started && (device->_pcm.size() >= 160 || (device->_tail && !device->_pcm.empty()))) {
                            consumed = std::min<size_t>(160,device->_pcm.size());
                            for (size_t i=0;i<consumed;i++) { samples[i] = device->_pcm.front(); device->_pcm.pop_front(); }
                            device->_consumed += consumed; device->_padding += 160-consumed;
                        } else if (device->_started && !device->_tail) { device->_underflow += 160; }
                    }
                    stamp.mSampleTime = tick*160;
                    AudioBufferList buffer = {1, {{1,sizeof(samples),samples}}};
                    delegate.deliverRecordedData(&flags,&stamp,0,160,&buffer,NULL,nil);
                    if (consumed && device.input) device.input(samples,consumed*2);
                }
                if (device->_playing) {
                    int16_t samples[240] = {}; stamp.mSampleTime = tick*240;
                    AudioBufferList buffer = {1, {{1,sizeof(samples),samples}}};
                    delegate.getPlayoutData(&flags,&stamp,0,240,&buffer);
                    // Test-only continuous decoded timeline, including silence; normal output is unchanged.
                    if (device->_timelineProbe && device.probeOutput) device.probeOutput(samples,sizeof(samples));
                    bool audible = false; for (int16_t sample : samples) if (sample) { audible = true; break; }
                    if (audible) { device->_outputHangover=20; device->_lastAudibleMs=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
                    if (device->_outputHangover && device.output) { device.output(samples,sizeof(samples)); --device->_outputHangover; }
                }
                if (++tick % 100 == 0) [device report];
            }
        }
    });
    return YES;
}
- (BOOL)terminateDevice {
    _stop = true;
    if (_clock.joinable()) { if (_clock.get_id()==std::this_thread::get_id()) _clock.detach(); else _clock.join(); }
    self.delegate = nil; self.isInitialized = NO; return YES;
}
- (BOOL)initializePlayout { self.isPlayoutInitialized=YES; return YES; }
- (BOOL)initializeRecording { self.isRecordingInitialized=YES; return YES; }
- (BOOL)startPlayout { _playing=true; return YES; }
- (BOOL)stopPlayout { _playing=false; return YES; }
- (BOOL)startRecording { _recording=true; return YES; }
- (BOOL)stopRecording { _recording=false; return YES; }
- (int)push:(const void *)bytes length:(size_t)length {
    if (length%2) return -1;
    std::lock_guard<std::mutex> lock(_mutex);
    if (_pcm.size()+length/2 > 16000) return 110;
    auto samples = (const int16_t *)bytes; _pcm.insert(_pcm.end(),samples,samples+length/2); return 0;
}
- (int)pending { std::lock_guard<std::mutex> lock(_mutex); return (int)_pcm.size(); }
- (void)finishInput { _tail = true; }
- (int64_t)outputIdleMs {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()-_lastAudibleMs;
}
- (void)report {
    NSDictionary *snapshot;
    { std::lock_guard<std::mutex> lock(_mutex); snapshot=@{@"type":@"_webrtc.input",@"consumed_samples":@(_consumed),@"pending_samples":@(_pcm.size()),@"underflow_samples":@(_underflow),@"tail_padding_samples":@(_padding)}; }
    if(self.diagnostic)self.diagnostic(snapshot);
}
@end

@interface LCRTCBridge : NSObject <RTCPeerConnectionDelegate, RTCDataChannelDelegate>
@property(nonatomic,strong) RTCPeerConnectionFactory *factory;
@property(atomic,strong) RTCPeerConnection *peer;
@property(atomic,strong) LCRTCDevice *device;
@property(atomic,strong) RTCDataChannel *control;
@property(nonatomic,strong) RTCRtpSender *sender;
@property(nonatomic,strong) RTCAudioTrack *inputTrack;
@property(nonatomic,strong) NSMutableArray<RTCDataChannel *> *channels;
@property(nonatomic,assign) LCRTCEvent callback;
@property(nonatomic,assign) void *context;
@property(nonatomic,assign) BOOL offered;
@property(atomic,assign) BOOL closed;
@property(atomic,assign) BOOL finishing;
@property(atomic,assign) BOOL inputEnded;
@property(nonatomic,strong) dispatch_source_t statsTimer;
@property(atomic,assign) NSUInteger iceRevision;
- (void)emit:(int)kind bytes:(const void *)bytes length:(size_t)length value:(int)value;
@end
@implementation LCRTCBridge
- (void)emit:(int)kind bytes:(const void *)bytes length:(size_t)length value:(int)value {
    @synchronized(self) { if (_callback && !_closed) _callback(_context,kind,bytes,length,value); }
}
- (void)json:(NSDictionary *)root {
    NSData *data=[NSJSONSerialization dataWithJSONObject:root options:0 error:nil]; [self emit:0 bytes:data.bytes length:data.length value:0];
}
- (void)setSending:(BOOL)enabled {
    RTCRtpParameters *p=self.sender.parameters;
    for (RTCRtpEncodingParameters *encoding in p.encodings) { encoding.isActive=enabled; encoding.maxBitrateBps=@32000; }
    self.sender.parameters=p;
    if(enabled) self.sender.track=self.inputTrack;
}
- (void)offerReady {
    @synchronized(self) {
        if (_offered || !_peer.localDescription.sdp.length || _peer.iceGatheringState != RTCIceGatheringStateComplete) return;
        _offered=YES;
    }
    NSData *sdp=[_peer.localDescription.sdp dataUsingEncoding:NSUTF8StringEncoding]; [self emit:1 bytes:sdp.bytes length:sdp.length value:0];
}
- (void)dataChannelDidChangeState:(RTCDataChannel *)dataChannel {}
- (void)dataChannel:(RTCDataChannel *)channel didReceiveMessageWithBuffer:(RTCDataBuffer *)buffer {
    const double receivedAt=NSDate.date.timeIntervalSince1970;
    const double receivedUptime=NSProcessInfo.processInfo.systemUptime;
    NSDictionary *root=[NSJSONSerialization JSONObjectWithData:buffer.data options:0 error:nil];
    if ([root[@"type"] isEqual:@"session.created"]) [self json:@{@"type":@"_webrtc.stage",@"stage":@"greeting",@"channel":@(channel.channelId)}];
    if ([root[@"type"] isEqual:@"session.created"]) self.control=channel;
    if ([root[@"type"] isEqual:@"session.updated"]) [self setSending:YES];
    if ([root[@"type"] isEqual:@"session.finished"]) {
        @synchronized(self) { if(_finishing)return;_finishing=YES; }
        // The reliable control channel may finish before RTP's decoded playout tail.
        // Keep delivering PCM to the Swift receiver, then publish the terminal event last.
        NSData *terminal=buffer.data;
        [self json:@{@"type":@"_webrtc.stage",@"stage":@"playout.draining",@"remote_finished":@YES}];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            auto began=std::chrono::steady_clock::now();
            int64_t waited=0; BOOL drained=NO;
            while(!self.closed && waited<30000) {
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
                waited=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-began).count();
                if(waited>=500 && [self.device outputIdleMs]>=350){drained=YES;break;}
            }
            if(self.closed)return;
            [self json:@{@"type":@"_webrtc.stage",@"stage":drained?@"playout.drained":@"playout.timeout",@"drain_wait_ms":@(waited)}];
            if(!drained)[self json:@{@"type":@"error",@"error":@{@"code":@"playout_timeout",@"message":@"服务器已完成，但译音尾部未在三十秒内排空"}}];
            [self emit:0 bytes:terminal.bytes length:terminal.length value:0];
        });
        return;
    }
    NSMutableDictionary *timed=[root mutableCopy];
    if(timed) {
        timed[@"_native_received_unix_seconds"]=@(receivedAt);
        timed[@"_native_received_uptime_seconds"]=@(receivedUptime);
        [self json:timed];
    }
    else [self emit:0 bytes:buffer.data.bytes length:buffer.data.length value:0];
}
- (void)peerConnection:(RTCPeerConnection *)peer didOpenDataChannel:(RTCDataChannel *)channel { channel.delegate=self; @synchronized(self) { [_channels addObject:channel]; } }
- (void)peerConnection:(RTCPeerConnection *)peer didChangeSignalingState:(RTCSignalingState)state {}
- (void)peerConnection:(RTCPeerConnection *)peer didAddStream:(RTCMediaStream *)stream {}
- (void)peerConnection:(RTCPeerConnection *)peer didRemoveStream:(RTCMediaStream *)stream {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peer {}
- (void)peerConnection:(RTCPeerConnection *)peer didChangeIceConnectionState:(RTCIceConnectionState)state {
    NSUInteger revision; @synchronized(self) { revision=++_iceRevision; }
    [self json:@{@"type":@"_webrtc.stage",@"stage":@"ice.state",@"ice_state":@(state)}];
    // session.finished already arrived; complete the bounded decoded playout drain.
    if (self.finishing || self.inputEnded) return;
    if (state==RTCIceConnectionStateFailed) [self emit:3 bytes:NULL length:0 value:1];
    if (state==RTCIceConnectionStateDisconnected) {
        __weak LCRTCBridge *weak=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            LCRTCBridge *bridge=weak;
            if (bridge && !bridge.closed && !bridge.finishing && !bridge.inputEnded && bridge.iceRevision==revision && bridge.peer.iceConnectionState==RTCIceConnectionStateDisconnected)
                [bridge emit:3 bytes:NULL length:0 value:6];
        });
    }
}
- (void)peerConnection:(RTCPeerConnection *)peer didChangeIceGatheringState:(RTCIceGatheringState)state { [self offerReady]; }
- (void)peerConnection:(RTCPeerConnection *)peer didGenerateIceCandidate:(RTCIceCandidate *)candidate {}
- (void)peerConnection:(RTCPeerConnection *)peer didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {}
@end

void *lc_rtc_create(LCRTCEvent callback,void *context) {
    static dispatch_once_t once; dispatch_once(&once,^{ RTCInitializeSSL(); RTCSetMinDebugLogLevel(RTCLoggingSeverityError); });
    LCRTCBridge *b=[LCRTCBridge new]; b.callback=callback; b.context=context; b.channels=[NSMutableArray new]; b.device=[LCRTCDevice new];
    __weak LCRTCBridge *weak=b;
    b.device.output=^(const void *bytes,size_t length) { [weak emit:2 bytes:bytes length:length value:24000]; };
    b.device.probeOutput=^(const void *bytes,size_t length) { [weak emit:5 bytes:bytes length:length value:24000]; };
    b.device.input=^(const void *bytes,size_t length) { [weak emit:4 bytes:bytes length:length value:16000]; };
    b.device.diagnostic=^(NSDictionary *root) { [weak json:root]; };
    b.factory=[[RTCPeerConnectionFactory alloc] initWithEncoderFactory:nil decoderFactory:nil audioDevice:b.device];
    RTCConfiguration *config=[RTCConfiguration new]; config.iceServers=@[]; config.sdpSemantics=RTCSdpSemanticsUnifiedPlan;
    RTCMediaConstraints *constraints=[[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
    b.peer=[b.factory peerConnectionWithConfiguration:config constraints:constraints delegate:b];
    if (!b.peer) { [b.device terminateDevice]; b.factory=nil; return NULL; }
    NSDictionary *disable=@{@"googEchoCancellation":@"false",@"googAutoGainControl":@"false",@"googNoiseSuppression":@"false",@"googHighpassFilter":@"false"};
    RTCAudioSource *source=[b.factory audioSourceWithConstraints:[[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:disable]];
    RTCAudioTrack *track=[b.factory audioTrackWithSource:source trackId:@"livecaption-pcm"];
    b.inputTrack=track; b.sender=[b.peer addTrack:track streamIds:@[@"livecaption"]]; b.sender.track=nil;
    RTCDataChannel *channel=[b.peer dataChannelForLabel:@"oai-events" configuration:[RTCDataChannelConfiguration new]]; channel.delegate=b; [b.channels addObject:channel];
    [b.peer offerForConstraints:constraints completionHandler:^(RTCSessionDescription *sdp,NSError *error) {
        LCRTCBridge *bridge=weak; if (!bridge || bridge.closed) return;
        if (error) { [bridge emit:3 bytes:NULL length:0 value:2]; return; }
        [bridge.peer setLocalDescription:sdp completionHandler:^(NSError *error) {
            if (error) [weak emit:3 bytes:NULL length:0 value:3]; else { [weak setSending:NO]; [weak offerReady]; }
        }];
    }];
    b.statsTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_timer(b.statsTimer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,10000000);
    dispatch_source_set_event_handler(b.statsTimer,^{
        LCRTCBridge *bridge=weak; if (!bridge || bridge.closed) return;
        [bridge.peer statisticsWithCompletionHandler:^(RTCStatisticsReport *report) {
            for (RTCStatistics *s in report.statistics.allValues) {
                BOOL probe=[NSProcessInfo.processInfo.environment[@"LIVECAPTION_AUDIO_TIMELINE_PROBE"] isEqual:@"1"];
                if (![@[@"outbound-rtp",@"remote-inbound-rtp",@"candidate-pair",@"transport",@"media-source"] containsObject:s.type] && !(probe && [s.type isEqual:@"inbound-rtp"])) continue;
                if ([s.type isEqual:@"candidate-pair"] && ![(NSNumber *)s.values[@"nominated"] boolValue]) continue;
                NSMutableDictionary *safe=[@{@"type":@"_webrtc.stats",@"kind":s.type} mutableCopy];
                // Explicit allowlist excludes addresses, candidate IDs, certificates and credentials.
                for (NSString *key in @[@"packetsSent",@"bytesSent",@"bytesReceived",@"packetsLost",@"fractionLost",@"roundTripTime",@"state",@"nominated",@"requestsSent",@"responsesReceived",@"requestsReceived",@"responsesSent",@"consentRequestsSent",@"currentRoundTripTime",@"lastPacketReceivedTimestamp",@"lastPacketSentTimestamp",@"dtlsState",@"iceState"]) if (s.values[key]) safe[key]=s.values[key];
                for (NSString *key in @[@"totalPacketSendDelay",@"totalEncodeTime",@"totalSamplesDuration",@"totalAudioEnergy",@"jitter",@"targetBitrate",@"totalSamplesSent",@"retransmittedPacketsSent"]) if(s.values[key])safe[key]=s.values[key];
                if(probe) for(NSString *key in @[@"packetsReceived",@"jitterBufferDelay",@"jitterBufferEmittedCount",@"jitterBufferTargetDelay",@"jitterBufferMinimumDelay",@"concealedSamples",@"silentConcealedSamples",@"totalSamplesReceived",@"insertedSamplesForDeceleration",@"removedSamplesForAcceleration"]) if(s.values[key])safe[key]=s.values[key];
                [weak json:safe];
            }
        }];
    }); dispatch_resume(b.statsTimer);
    return (__bridge_retained void *)b;
}
void lc_rtc_answer(void *handle,const void *bytes,size_t length) {
    LCRTCBridge *b=(__bridge LCRTCBridge *)handle;
    __weak LCRTCBridge *weak=b;
    [b setSending:NO];
    NSString *sdp=[[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    [b.peer setRemoteDescription:[[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:sdp] completionHandler:^(NSError *error) { if(error)[weak emit:3 bytes:NULL length:0 value:4]; }];
}
int lc_rtc_send(void *handle,const void *bytes,size_t length) {
    LCRTCBridge *b=(__bridge LCRTCBridge *)handle;
    if (b.closed || b.control.readyState!=RTCDataChannelStateOpen) return -1;
    return [b.control sendData:[[RTCDataBuffer alloc] initWithData:[NSData dataWithBytes:bytes length:length] isBinary:NO]] ? 0 : -2;
}
int lc_rtc_push(void *handle,const void *bytes,size_t length) { return [((__bridge LCRTCBridge *)handle).device push:bytes length:length]; }
int lc_rtc_pending(void *handle) { return [((__bridge LCRTCBridge *)handle).device pending]; }
void lc_rtc_finish_input(void *handle) {
    LCRTCBridge *b=(__bridge LCRTCBridge *)handle;b.inputEnded=YES;[b.device finishInput];
}
void lc_rtc_report(void *handle) { [((__bridge LCRTCBridge *)handle).device report]; }
void lc_rtc_close(void *handle) {
    if (!handle) return;
    LCRTCBridge *b=(__bridge_transfer LCRTCBridge *)handle;
    @synchronized(b) { b.closed=YES; b.callback=NULL; }
    if(b.statsTimer)dispatch_source_cancel(b.statsTimer);
    b.peer.delegate=nil; for(RTCDataChannel *ch in b.channels)ch.delegate=nil;
    [b.device terminateDevice]; [b.peer close]; b.peer=nil; b.factory=nil; b.device=nil;
}
