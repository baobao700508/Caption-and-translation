#import "AoqBridge.h"
#import <AoqClientSdk/AoqClientEngine.h>

@interface LCAoqBridge : NSObject <AoqEngineDelegate,AoqAudioFrameDelegate>
@property(nonatomic,strong) AoqClientEngine *engine;
@property(nonatomic,assign) LCAoqCallback callback;
@property(nonatomic,assign) void *context;
@property(nonatomic,strong) NSMutableSet *reportedPublishFormats;
@end
@implementation LCAoqBridge
- (void)emit:(int)kind bytes:(const void *)bytes length:(size_t)length value:(int)value {
    @synchronized(self) { if (_callback) _callback(_context,kind,bytes,length,value); }
}
- (void)onConnectionStatusChange:(AoqConnectionStatus)status { [self emit:1 bytes:NULL length:0 value:(int)status]; }
- (void)onDataMsg:(AoqDataMsg *)msg { [self emit:0 bytes:msg.data.bytes length:msg.data.length value:0]; }
- (void)onError:(NSInteger)code message:(NSString *)message { [self emit:3 bytes:NULL length:0 value:(int)code]; }
- (void)onWarning:(NSInteger)code message:(NSString *)message {}
- (void)onStats:(AoqStats *)stats {
    if (!stats.networkStats) return;
    AoqNetworkStats *n = stats.networkStats;
    NSMutableArray *audio = [NSMutableArray new];
    for (AoqAudioPublishStats *a in stats.audioPublishStats) [audio addObject:@{@"track":@(a.trackType),@"bitrate":@(a.bitrate),@"bytes":@(a.bytes)}];
    NSData *info = [NSJSONSerialization dataWithJSONObject:@{@"type":@"_aoq.stats",@"send_bitrate":@(n.sendBitrate),@"rtt":@(n.rtt),@"loss":@(n.loss),@"audio":audio} options:0 error:nil];
    [self emit:0 bytes:info.bytes length:info.length value:0];
}
- (void)onAudioDeviceStateChanged:(AoqAudioDeviceState *)state {}
- (void)onAudioDeviceRouteChanged:(NSInteger)routeType {}
- (void)onAudioFileState:(AoqAudioFileState *)state {}
- (void)onLocalAudioVolumeIndication:(AoqAudioVolume *)volume {}
- (void)onVideoDeviceStateChanged:(AoqVideoDeviceState *)state {}
- (void)onPlaybackAudioFrame:(AoqAudioFrameData *)frame {
    if (frame.dataPtr && frame.numOfChannels == 1 && frame.bytesPerSample == 2 && !frame.autoGenMute)
        [self emit:2 bytes:frame.dataPtr length:frame.dataSize value:(int)frame.samplesPerSec];
}
- (void)onPublishAudioFrame:(AoqTrackType)trackType frame:(AoqAudioFrameData *)frame {
    NSString *key = [NSString stringWithFormat:@"%ld:%d",(long)trackType,frame.autoGenMute];
    if (![_reportedPublishFormats containsObject:key]) {
        [_reportedPublishFormats addObject:key];
        NSData *info = [NSJSONSerialization dataWithJSONObject:@{@"type":@"_aoq.publish_format",@"track":@(trackType),@"auto_generated_mute":@(frame.autoGenMute),@"sample_rate":@(frame.samplesPerSec),@"channels":@(frame.numOfChannels),@"data_size":@(frame.dataSize),@"samples":@(frame.numOfSamples),@"bytes_per_sample":@(frame.bytesPerSample)} options:0 error:nil];
        [self emit:0 bytes:info.bytes length:info.length value:0];
    }
    if (trackType == AoqTrackTypeAudio && frame.dataPtr && frame.numOfChannels == 1 && frame.bytesPerSample == 2)
        [self emit:(frame.autoGenMute ? 5 : 4) bytes:frame.dataPtr length:frame.dataSize value:(int)frame.samplesPerSec];
}
@end

void *lc_aoq_create(const char *work_dir,LCAoqCallback callback,void *context) {
    LCAoqBridge *bridge = [LCAoqBridge new]; bridge.reportedPublishFormats = [NSMutableSet new]; bridge.callback = callback; bridge.context = context;
    AoqCreateConfig *config = [AoqCreateConfig new]; config.workDir = [NSString stringWithUTF8String:work_dir]; config.enableDumpAudio = NO; config.extras = @"";
    bridge.engine = [AoqClientEngine createEngine:config delegate:bridge];
    if (!bridge.engine) return NULL;
    [bridge.engine enableSendMediaStream:AoqTrackTypeAudio enable:NO];
    return (__bridge_retained void *)bridge;
}
int lc_aoq_connect(void *handle,const void *json,size_t length) {
    LCAoqBridge *bridge = (__bridge LCAoqBridge *)handle;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:length] options:0 error:nil];
    if (!root) return -1;
    AoqConnectConfig *config = [AoqConnectConfig new];
    config.token = root[@"aoqTokenForClient"]; config.sid = root[@"sid"]; config.certFingerprint = root[@"clientRelayCertFingerprint"];
    config.workspaceIdHash = root[@"extraInfo"][@"workspaceIdHash"] ?: @"";
    NSMutableArray *endpoints = [NSMutableArray new];
    for (NSDictionary *item in root[@"clientRelayEndpoints"]) {
        AoqRelayEndpoint *ep = [AoqRelayEndpoint new]; ep.endpoint = item[@"endpoint"]; ep.port = [item[@"port"] integerValue]; ep.routeIndex = item[@"route_index"] ? [item[@"route_index"] integerValue] : endpoints.count;
        ep.tcpPort = [item[@"tcp_port"] integerValue]; [endpoints addObject:ep];
    }
    config.relayEndpoints = endpoints;
    AoqTrackParam *audio = [AoqTrackParam new]; audio.trackType = AoqTrackTypeAudio;
    AoqTrackParam *downlink = [AoqTrackParam new]; downlink.trackType = AoqTrackTypeAudio; downlink.trackMode = AoqTrackModeStream;
    AoqTrackParam *data = [AoqTrackParam new]; data.trackType = AoqTrackTypeData;
    config.publishTracks = @[audio,data]; config.subscribeTracks = @[downlink,data];
    AoqAudioCodecConfig *codec = [AoqAudioCodecConfig new]; codec.trackType = AoqTrackTypeAudio; codec.codecType = AoqEncoderTypeAudioOpus; codec.sampleRate = 16000; codec.channel = 1; codec.bitrate = 16000;
    int code = [bridge.engine setAudioEncoderConfig:codec]; if (code) return code;
    code = [bridge.engine setAudioDecoderConfig:codec]; if (code) return code;
    AoqAudioCaptureConfig *capture = [AoqAudioCaptureConfig new]; capture.isExternal = YES; capture.channel = 1;
    code = [bridge.engine startAudioCapture:capture]; if (code) return code;

    AoqAudioPlaybackConfig *playback = [AoqAudioPlaybackConfig new]; playback.isExternal = YES; playback.channel = 1;
    code = [bridge.engine startAudioPlayer:playback]; if (code) return code;
    [bridge.engine setAudioFrameObserver:bridge];
    AoqAudioObserverConfig *observer = [AoqAudioObserverConfig new]; observer.sampleRate = 24000; observer.channels = 1; observer.mode = AoqAudioObserverModeReadOnly;
    [bridge.engine enableAudioFrameObserver:YES audioSource:AoqAudioSourcePlayback config:observer];
    observer = [AoqAudioObserverConfig new]; observer.sampleRate = 16000; observer.channels = 1; observer.mode = AoqAudioObserverModeReadOnly;
    [bridge.engine enableAudioFrameObserver:YES audioSource:AoqAudioSourcePublish config:observer];
    return [bridge.engine connect:config];
}
int lc_aoq_send(void *handle,const void *json,size_t length) {
    LCAoqBridge *bridge = (__bridge LCAoqBridge *)handle;
    AoqDataMsg *msg = [AoqDataMsg new]; msg.data = [NSData dataWithBytes:json length:length];
    return [bridge.engine sendDataMsg:msg];
}
int lc_aoq_enable(void *handle) {
    LCAoqBridge *bridge = (__bridge LCAoqBridge *)handle;
    AoqAudioExternalStreamConfig *stream = [AoqAudioExternalStreamConfig new]; stream.trackType = AoqTrackTypeAudio; stream.codecType = AoqEncoderTypeAudioPCM; stream.sampleRate = 16000; stream.channels = 1; stream.playoutVolume = 0; stream.publishVolume = 100; stream.enable3A = NO; stream.maxBufferDuration = 300;
    int code = [bridge.engine addAudioExternalStream:@"livecaption" config:stream]; if (code) return code;
    return [bridge.engine enableSendMediaStream:AoqTrackTypeAudio enable:YES];
}
int lc_aoq_push(void *handle,const void *pcm,size_t length,int64_t timestamp_ms) {
    LCAoqBridge *bridge = (__bridge LCAoqBridge *)handle;
    AoqAudioFrameData *frame = [AoqAudioFrameData new]; frame.dataPtr = (void *)pcm; frame.dataSize = length; frame.numOfSamples = length/2; frame.bytesPerSample = 2; frame.numOfChannels = 1; frame.samplesPerSec = 16000;
    return [bridge.engine pushAudioExternalStreamData:@"livecaption" data:frame];
}
void lc_aoq_close(void *handle) {
    if (!handle) return;
    LCAoqBridge *bridge = (__bridge_transfer LCAoqBridge *)handle;
    @synchronized(bridge) { bridge.callback = NULL; }
    [bridge.engine enableSendMediaStream:AoqTrackTypeAudio enable:NO];
    [bridge.engine setAudioFrameObserver:nil]; [bridge.engine stopAudioCapture]; [bridge.engine stopAudioPlayer]; [bridge.engine disconnect]; [AoqClientEngine destroy]; bridge.engine = nil;
}
