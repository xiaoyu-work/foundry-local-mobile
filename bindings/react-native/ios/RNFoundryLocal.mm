// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// Objective-C++ shim for the React Native TurboModule. Extends
// `RCTEventEmitter` so it can push the four `FoundryLocal:*` events onto the
// JS thread, and forwards every JS-visible operation to `RNFoundryLocalCore`
// (Swift), which owns the handle registries and calls into the Swift
// binding.
//
// The split into a thin Obj-C++ facade plus a Swift core keeps the RN
// method-dispatch surface expressible with the RCT_EXPORT_* macros (which
// only exist for Obj-C++), while the real work lives in Swift where
// `async throws` and `AsyncThrowingStream` are idiomatic to consume.
//
// Behavioural parity with the Android module (`FoundryLocalModule.kt`) is
// deliberate — the JS side speaks one shape, and any divergence here would
// show up as inconsistent behaviour between iOS and Android at runtime.

#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTLog.h>

// Swift-generated header. CocoaPods produces this at pod build time when the
// pod contains Swift sources; the name matches the pod module name (which
// this podspec sets to `FoundryLocal`). If a consumer app renames the pod
// they must update this include.
#if __has_include(<FoundryLocal/FoundryLocal-Swift.h>)
#import <FoundryLocal/FoundryLocal-Swift.h>
#else
// SwiftPM / raw builds use an unprefixed import.
#import "FoundryLocal-Swift.h"
#endif

@interface RNFoundryLocal : RCTEventEmitter <RCTBridgeModule, RNFoundryLocalEmitting>
@property (nonatomic, strong) RNFoundryLocalCore *core;
@end

@implementation RNFoundryLocal

RCT_EXPORT_MODULE(RNFoundryLocal)

- (instancetype)init {
    self = [super init];
    if (self) {
        _core = [[RNFoundryLocalCore alloc] init];
        _core.host = self;
    }
    return self;
}

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

- (dispatch_queue_t)methodQueue {
    // Serve promise methods off the main thread; heavy work happens in
    // Swift's own Task { } contexts. A dedicated serial queue keeps
    // handle-registry writes in a predictable order.
    return dispatch_queue_create("com.foundrylocal.reactnative", DISPATCH_QUEUE_SERIAL);
}

- (NSArray<NSString *> *)supportedEvents {
    return @[
        @"FoundryLocal:delta",
        @"FoundryLocal:progress",
        @"FoundryLocal:end",
        @"FoundryLocal:error",
    ];
}

- (void)invalidate {
    [self.core invalidate];
    [super invalidate];
}

- (void)emitEvent:(NSString *)name body:(NSDictionary *)body {
    // RCTEventEmitter silently drops events emitted before any JS listener
    // subscribes; the emit(name:, body:) helper on the Swift side is
    // deliberately fire-and-forget with the same semantics.
    [self sendEventWithName:name body:body];
}

// -----------------------------------------------------------------------------
// Small NSError -> reject helpers
// -----------------------------------------------------------------------------

static NSString *codeForStatus(NSInteger status) {
    switch (status) {
        case 2: return @"invalidArgument";
        case 3: return @"invalidHandle";
        case 4: return @"invalidState";
        case 5: return @"notFound";
        case 6: return @"notImplemented";
        case 7: return @"cancelled";
        case 8: return @"network";
        case 9: return @"storage";
        case 10: return @"outOfMemory";
        case 11: return @"incompatible";
        case 12: return @"timeout";
        case 13: return @"unsupportedVersion";
        case 14: return @"memoryPressure";
        case 15: return @"shutdown";
        default: return @"internal";
    }
}

// Sync methods that throw a Swift error surface it to JS by raising an
// NSException. RN's method dispatch translates that into a JS exception,
// matching the Android side's behaviour where Kotlin throws propagate as
// JS-side rejections/throws. Silently returning a fallback would let JS
// consume a wrong-looking success value.
static void RaiseFromNSError(NSError *error) {
    if (!error) { return; }
    NSInteger status = 1;
    NSString *detail = nil;
    id statusVal = error.userInfo[@"status"];
    if ([statusVal isKindOfClass:[NSNumber class]]) { status = [statusVal integerValue]; }
    id detailVal = error.userInfo[@"detail"];
    if ([detailVal isKindOfClass:[NSString class]]) { detail = detailVal; }
    NSDictionary *userInfo = @{
        @"status": @(status),
        @"detail": detail ?: [NSNull null],
    };
    @throw [NSException exceptionWithName:codeForStatus(status)
                                   reason:error.localizedDescription ?: @"FoundryLocalError"
                                 userInfo:userInfo];
}

// -----------------------------------------------------------------------------
// Manager
// -----------------------------------------------------------------------------

RCT_EXPORT_METHOD(managerCreate:(NSString *)configJson
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    [self.core managerCreateWithConfigJson:configJson resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(managerShutdown:(nonnull NSNumber *)managerId
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    [self.core managerShutdownWithManagerId:managerId resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(managerRelease:(nonnull NSNumber *)managerId) {
    [self.core managerReleaseWithManagerId:managerId];
}

RCT_EXPORT_METHOD(managerUpdateSettings:(nonnull NSNumber *)managerId
                  configJson:(NSString *)configJson) {
    NSError *error = nil;
    [self.core managerUpdateSettingsWithManagerId:managerId configJson:configJson error:&error];
    if (error) { RCTLogError(@"managerUpdateSettings failed: %@", error); }
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(managerGetDeviceProfile:(nonnull NSNumber *)managerId) {
    NSError *error = nil;
    NSString *json = [self.core managerGetDeviceProfileWithManagerId:managerId error:&error];
    if (error) { RaiseFromNSError(error); }
    return json;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(managerVersion:(nonnull NSNumber *)managerId) {
    NSError *error = nil;
    NSString *value = [self.core managerVersionWithManagerId:managerId error:&error];
    if (error) { RaiseFromNSError(error); }
    return value;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(managerRuntimeVersion:(nonnull NSNumber *)managerId) {
    NSError *error = nil;
    NSString *value = [self.core managerRuntimeVersionWithManagerId:managerId error:&error];
    if (error) { RaiseFromNSError(error); }
    return value;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(managerIsRuntimeAvailable:(nonnull NSNumber *)managerId) {
    NSError *error = nil;
    NSNumber *value = [self.core managerIsRuntimeAvailableWithManagerId:managerId error:&error];
    if (error) { RaiseFromNSError(error); }
    return value;
}

RCT_EXPORT_METHOD(managerSetLogLevel:(nonnull NSNumber *)managerId
                  level:(nonnull NSNumber *)level) {
    NSError *error = nil;
    [self.core managerSetLogLevelWithManagerId:managerId level:level error:&error];
    if (error) { RCTLogError(@"managerSetLogLevel failed: %@", error); }
}

// -----------------------------------------------------------------------------
// Load model
// -----------------------------------------------------------------------------

RCT_EXPORT_METHOD(loadModel:(nonnull NSNumber *)managerId
                  modelPath:(NSString *)modelPath
                  optionsJson:(NSString *)optionsJson
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    [self.core loadModelWithManagerId:managerId
                            modelPath:modelPath
                          optionsJson:optionsJson
                              resolve:resolve
                               reject:reject];
}

// -----------------------------------------------------------------------------
// Model
// -----------------------------------------------------------------------------

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(modelGetInfo:(nonnull NSNumber *)modelId) {
    NSError *error = nil;
    NSString *value = [self.core modelGetInfoWithModelId:modelId error:&error];
    if (error) { RaiseFromNSError(error); }
    return value;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(modelIsCached:(nonnull NSNumber *)modelId) {
    NSError *error = nil;
    NSNumber *value = [self.core modelIsCachedWithModelId:modelId error:&error];
    if (error) { RaiseFromNSError(error); }
    return value;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(modelIsLoaded:(nonnull NSNumber *)modelId) {
    NSError *error = nil;
    NSNumber *value = [self.core modelIsLoadedWithModelId:modelId error:&error];
    if (error) { RaiseFromNSError(error); }
    return value;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(modelGetPath:(nonnull NSNumber *)modelId) {
    NSError *error = nil;
    NSString *value = [self.core modelGetPathWithModelId:modelId error:&error];
    if (error) { RaiseFromNSError(error); }
    return value;
}

RCT_EXPORT_METHOD(modelLoad:(nonnull NSNumber *)modelId
                  optionsJson:(NSString *)optionsJson
                  subscriptionId:(NSString *)subscriptionId
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    [self.core modelLoadWithModelId:modelId
                        optionsJson:optionsJson
                     subscriptionId:subscriptionId
                            resolve:resolve
                             reject:reject];
}

RCT_EXPORT_METHOD(modelUnload:(nonnull NSNumber *)modelId
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    [self.core modelUnloadWithModelId:modelId resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(modelRelease:(nonnull NSNumber *)modelId) {
    [self.core modelReleaseWithModelId:modelId];
}

// -----------------------------------------------------------------------------
// Sessions
// -----------------------------------------------------------------------------

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(sessionCreate:(nonnull NSNumber *)modelId
                                       optionsJson:(NSString *)optionsJson) {
    NSError *error = nil;
    NSNumber *value = [self.core sessionCreateWithModelId:modelId
                                              optionsJson:optionsJson
                                                    error:&error];
    if (error) { RaiseFromNSError(error); }
    return value;
}

RCT_EXPORT_METHOD(sessionRelease:(nonnull NSNumber *)sessionId) {
    [self.core sessionReleaseWithSessionId:sessionId];
}

RCT_EXPORT_METHOD(sessionSetOptions:(nonnull NSNumber *)sessionId
                  optionsJson:(NSString *)optionsJson) {
    NSError *error = nil;
    [self.core sessionSetOptionsWithSessionId:sessionId
                                  optionsJson:optionsJson
                                        error:&error];
    if (error) { RCTLogError(@"sessionSetOptions failed: %@", error); }
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(sessionExportHistory:(nonnull NSNumber *)sessionId) {
    NSError *error = nil;
    NSString *value = [self.core sessionExportHistoryWithSessionId:sessionId error:&error];
    if (error) { RaiseFromNSError(error); }
    return value;
}

RCT_EXPORT_METHOD(sessionRestoreHistory:(nonnull NSNumber *)sessionId
                  historyJson:(NSString *)historyJson) {
    NSError *error = nil;
    [self.core sessionRestoreHistoryWithSessionId:sessionId
                                       historyJson:historyJson
                                             error:&error];
    if (error) { RCTLogError(@"sessionRestoreHistory failed: %@", error); }
}

RCT_EXPORT_METHOD(sessionClearHistory:(nonnull NSNumber *)sessionId) {
    NSError *error = nil;
    [self.core sessionClearHistoryWithSessionId:sessionId error:&error];
    if (error) { RCTLogError(@"sessionClearHistory failed: %@", error); }
}

RCT_EXPORT_METHOD(sessionUndoTurns:(nonnull NSNumber *)sessionId
                  count:(nonnull NSNumber *)count) {
    NSError *error = nil;
    [self.core sessionUndoTurnsWithSessionId:sessionId count:count error:&error];
    if (error) { RCTLogError(@"sessionUndoTurns failed: %@", error); }
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(sessionGetTurnCount:(nonnull NSNumber *)sessionId) {
    NSError *error = nil;
    NSNumber *value = [self.core sessionGetTurnCountWithSessionId:sessionId error:&error];
    if (error) { RaiseFromNSError(error); }
    return value;
}

RCT_EXPORT_METHOD(sessionComplete:(nonnull NSNumber *)sessionId
                  requestJson:(NSString *)requestJson
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    [self.core sessionCompleteWithSessionId:sessionId
                                requestJson:requestJson
                                    resolve:resolve
                                     reject:reject];
}

RCT_EXPORT_METHOD(sessionCompleteStreaming:(nonnull NSNumber *)sessionId
                  requestJson:(NSString *)requestJson
                  subscriptionId:(NSString *)subscriptionId
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    [self.core sessionCompleteStreamingWithSessionId:sessionId
                                         requestJson:requestJson
                                      subscriptionId:subscriptionId
                                             resolve:resolve
                                              reject:reject];
}

RCT_EXPORT_METHOD(sessionSubmitToolResultsStreaming:(nonnull NSNumber *)sessionId
                  resultsJson:(NSString *)resultsJson
                  subscriptionId:(NSString *)subscriptionId
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    [self.core sessionSubmitToolResultsStreamingWithSessionId:sessionId
                                                  resultsJson:resultsJson
                                               subscriptionId:subscriptionId
                                                      resolve:resolve
                                                       reject:reject];
}

RCT_EXPORT_METHOD(sessionTranscribe:(nonnull NSNumber *)sessionId
                  requestJson:(NSString *)requestJson
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    [self.core sessionTranscribeWithSessionId:sessionId
                                  requestJson:requestJson
                                      resolve:resolve
                                       reject:reject];
}

RCT_EXPORT_METHOD(sessionTranscribeStreaming:(nonnull NSNumber *)sessionId
                  requestJson:(NSString *)requestJson
                  subscriptionId:(NSString *)subscriptionId
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    [self.core sessionTranscribeStreamingWithSessionId:sessionId
                                           requestJson:requestJson
                                        subscriptionId:subscriptionId
                                               resolve:resolve
                                                reject:reject];
}

RCT_EXPORT_METHOD(sessionPushAudio:(nonnull NSNumber *)sessionId
                  pcmBase64:(NSString *)pcmBase64
                  sampleRate:(nonnull NSNumber *)sampleRate
                  channels:(nonnull NSNumber *)channels
                  isFinal:(BOOL)isFinal) {
    NSError *error = nil;
    [self.core sessionPushAudioWithSessionId:sessionId
                                    pcmBase64:pcmBase64
                                   sampleRate:sampleRate
                                     channels:channels
                                      isFinal:@(isFinal)
                                        error:&error];
    if (error) { RCTLogError(@"sessionPushAudio failed: %@", error); }
}

RCT_EXPORT_METHOD(sessionEmbed:(nonnull NSNumber *)sessionId
                  requestJson:(NSString *)requestJson
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    [self.core sessionEmbedWithSessionId:sessionId
                             requestJson:requestJson
                                 resolve:resolve
                                  reject:reject];
}

// -----------------------------------------------------------------------------
// Subscription lifecycle
// -----------------------------------------------------------------------------

RCT_EXPORT_METHOD(cancelSubscription:(NSString *)subscriptionId) {
    [self.core cancelSubscription:subscriptionId];
}

// NativeEventEmitter requires these on every event-emitting module. No
// per-listener bookkeeping is needed on this module.
RCT_EXPORT_METHOD(addListener:(NSString *)eventName) {}
RCT_EXPORT_METHOD(removeListeners:(nonnull NSNumber *)count) {}

@end
