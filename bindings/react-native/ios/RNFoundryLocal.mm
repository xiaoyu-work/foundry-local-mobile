// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// iOS TurboModule scaffold for @foundry-local/react-native.
//
// This file is deliberately a scaffold: the iOS native implementation is not
// yet wired because it wraps the Swift binding at `bindings/ios/`, which is
// still being written. Every method rejects with a `notImplemented` error at
// runtime so an app that calls into the module fails fast and loudly, rather
// than silently no-op'ing and hiding the missing native implementation. Do
// not "fix" a method by returning `nil` or an empty JSON string — that would
// obscure the fact that iOS is not yet wired.
//
// When the Swift binding lands the follow-up task is to:
//   1. Replace the reject-only bodies with calls into `FoundryLocalKit`
//      (the pod name of the Swift binding).
//   2. Hook the `NativeEventEmitter` up to a Swift emitter shim so the
//      four `FoundryLocal:*` events reach JS on the same shape as Android.
//   3. Delete this comment.

#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RNFoundryLocal : RCTEventEmitter <RCTBridgeModule>
@end

@implementation RNFoundryLocal

RCT_EXPORT_MODULE(RNFoundryLocal);

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (NSArray<NSString *> *)supportedEvents {
  return @[
    @"FoundryLocal:delta",
    @"FoundryLocal:progress",
    @"FoundryLocal:end",
    @"FoundryLocal:error",
  ];
}

#pragma mark - Reject helpers

// Every reject here uses the same "notImplemented" code the TypeScript layer
// maps to `FoundryLocalErrorCode.notImplemented`. The message points at the
// tracking issue so a developer who hits it knows what to do next.
static NSError *FLMNotImplementedError(void) {
  return [NSError errorWithDomain:@"FoundryLocalError"
                             code:6
                         userInfo:@{
                           NSLocalizedDescriptionKey:
                               @"iOS native implementation is not yet wired. "
                               @"See github.com/microsoft/foundry-local-mobile "
                               @"tracking issue for status.",
                           @"status": @6,
                         }];
}

static void FLMReject(RCTPromiseRejectBlock reject) {
  NSError *error = FLMNotImplementedError();
  reject(@"notImplemented", error.localizedDescription, error);
}

#pragma mark - Manager

RCT_REMAP_METHOD(managerCreate,
                 managerCreateWithConfig:(NSString *)configJson
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

RCT_REMAP_METHOD(managerShutdown,
                 managerShutdownWithId:(nonnull NSNumber *)managerId
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

RCT_EXPORT_METHOD(managerRelease:(nonnull NSNumber *)managerId) {
  // Intentionally silent: releasing an unwired handle is a no-op that must
  // not throw on the app-shutdown path.
}

RCT_EXPORT_METHOD(managerUpdateSettings:(nonnull NSNumber *)managerId
                  configJson:(NSString *)configJson) {
  @throw [NSException exceptionWithName:@"FoundryLocalNotImplemented"
                                 reason:@"iOS native implementation not yet wired"
                               userInfo:nil];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(managerGetDeviceProfile:(nonnull NSNumber *)managerId) {
  @throw [NSException exceptionWithName:@"FoundryLocalNotImplemented"
                                 reason:@"iOS native implementation not yet wired"
                               userInfo:nil];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(managerGetCatalog:(nonnull NSNumber *)managerId) {
  @throw [NSException exceptionWithName:@"FoundryLocalNotImplemented"
                                 reason:@"iOS native implementation not yet wired"
                               userInfo:nil];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(managerVersion:(nonnull NSNumber *)managerId) {
  return @"";
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(managerRuntimeVersion:(nonnull NSNumber *)managerId) {
  return @"";
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(managerIsRuntimeAvailable:(nonnull NSNumber *)managerId) {
  return @NO;
}

RCT_EXPORT_METHOD(managerSetLogLevel:(nonnull NSNumber *)managerId level:(nonnull NSNumber *)level) {
  // Log-level updates are silently dropped until the Swift binding lands;
  // failing here would break apps that call setLogLevel defensively on
  // startup, before they know whether they will actually use the SDK.
}

#pragma mark - addModelSource

RCT_REMAP_METHOD(addModelSource,
                 addModelSourceWithManagerId:(nonnull NSNumber *)managerId
                 sourceJson:(NSString *)sourceJson
                 subscriptionId:(NSString *)subscriptionId
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

#pragma mark - Catalog

RCT_REMAP_METHOD(catalogListModels,
                 catalogListModelsWithId:(nonnull NSNumber *)catalogId
                 filterJson:(NSString *)filterJson
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(catalogListCachedModels:(nonnull NSNumber *)catalogId) {
  return @"{\"models\":[]}";
}

RCT_REMAP_METHOD(catalogGetModel,
                 catalogGetModelWithId:(nonnull NSNumber *)catalogId
                 alias:(NSString *)alias
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

RCT_REMAP_METHOD(catalogGetModelById,
                 catalogGetModelByIdWithId:(nonnull NSNumber *)catalogId
                 modelId:(NSString *)modelId
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(catalogGetCacheSizeBytes:(nonnull NSNumber *)catalogId) {
  return @0;
}

#pragma mark - Model

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(modelGetInfo:(nonnull NSNumber *)modelId) {
  @throw [NSException exceptionWithName:@"FoundryLocalNotImplemented"
                                 reason:@"iOS native implementation not yet wired"
                               userInfo:nil];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(modelIsPackage:(nonnull NSNumber *)modelId) {
  return @NO;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(modelIsCached:(nonnull NSNumber *)modelId) {
  return @NO;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(modelIsLoaded:(nonnull NSNumber *)modelId) {
  return @NO;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(modelGetPath:(nonnull NSNumber *)modelId) {
  return @"";
}

RCT_REMAP_METHOD(modelLoad,
                 modelLoadWithId:(nonnull NSNumber *)modelId
                 optionsJson:(NSString *)optionsJson
                 subscriptionId:(NSString *)subscriptionId
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

RCT_REMAP_METHOD(modelUnload,
                 modelUnloadWithId:(nonnull NSNumber *)modelId
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

RCT_REMAP_METHOD(modelDelete,
                 modelDeleteWithId:(nonnull NSNumber *)modelId
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

RCT_EXPORT_METHOD(modelRelease:(nonnull NSNumber *)modelId) {
  // Intentionally silent.
}

#pragma mark - Package

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(packageGetVariants:(nonnull NSNumber *)modelId) {
  @throw [NSException exceptionWithName:@"FoundryLocalNotImplemented"
                                 reason:@"iOS native implementation not yet wired"
                               userInfo:nil];
}

RCT_EXPORT_METHOD(packageSelectVariant:(nonnull NSNumber *)modelId variantId:(NSString *)variantId) {
  @throw [NSException exceptionWithName:@"FoundryLocalNotImplemented"
                                 reason:@"iOS native implementation not yet wired"
                               userInfo:nil];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(packageSelectBestVariant:(nonnull NSNumber *)modelId
                                       constraintsJson:(NSString *)constraintsJson) {
  return @"";
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(packageGetVariant:(nonnull NSNumber *)modelId
                                       variantId:(NSString *)variantId) {
  return @0;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(packageEstimateDownload:(nonnull NSNumber *)modelId
                                       variantIdsJson:(NSString *)variantIdsJson) {
  @throw [NSException exceptionWithName:@"FoundryLocalNotImplemented"
                                 reason:@"iOS native implementation not yet wired"
                               userInfo:nil];
}

#pragma mark - Session

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(sessionCreate:(nonnull NSNumber *)modelId
                                       optionsJson:(NSString *)optionsJson) {
  @throw [NSException exceptionWithName:@"FoundryLocalNotImplemented"
                                 reason:@"iOS native implementation not yet wired"
                               userInfo:nil];
}

RCT_EXPORT_METHOD(sessionRelease:(nonnull NSNumber *)sessionId) {
  // Intentionally silent.
}

RCT_EXPORT_METHOD(sessionSetOptions:(nonnull NSNumber *)sessionId optionsJson:(NSString *)optionsJson) {
  @throw [NSException exceptionWithName:@"FoundryLocalNotImplemented"
                                 reason:@"iOS native implementation not yet wired"
                               userInfo:nil];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(sessionExportHistory:(nonnull NSNumber *)sessionId) {
  return @"{}";
}

RCT_EXPORT_METHOD(sessionRestoreHistory:(nonnull NSNumber *)sessionId historyJson:(NSString *)historyJson) {
  @throw [NSException exceptionWithName:@"FoundryLocalNotImplemented"
                                 reason:@"iOS native implementation not yet wired"
                               userInfo:nil];
}

RCT_EXPORT_METHOD(sessionClearHistory:(nonnull NSNumber *)sessionId) {
  // Intentionally silent.
}

RCT_EXPORT_METHOD(sessionUndoTurns:(nonnull NSNumber *)sessionId count:(nonnull NSNumber *)count) {
  // Intentionally silent.
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(sessionGetTurnCount:(nonnull NSNumber *)sessionId) {
  return @0;
}

RCT_REMAP_METHOD(sessionComplete,
                 sessionCompleteWithId:(nonnull NSNumber *)sessionId
                 requestJson:(NSString *)requestJson
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

RCT_REMAP_METHOD(sessionCompleteStreaming,
                 sessionCompleteStreamingWithId:(nonnull NSNumber *)sessionId
                 requestJson:(NSString *)requestJson
                 subscriptionId:(NSString *)subscriptionId
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

RCT_REMAP_METHOD(sessionSubmitToolResultsStreaming,
                 sessionSubmitToolResultsStreamingWithId:(nonnull NSNumber *)sessionId
                 resultsJson:(NSString *)resultsJson
                 subscriptionId:(NSString *)subscriptionId
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

RCT_REMAP_METHOD(sessionTranscribe,
                 sessionTranscribeWithId:(nonnull NSNumber *)sessionId
                 requestJson:(NSString *)requestJson
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

RCT_REMAP_METHOD(sessionTranscribeStreaming,
                 sessionTranscribeStreamingWithId:(nonnull NSNumber *)sessionId
                 requestJson:(NSString *)requestJson
                 subscriptionId:(NSString *)subscriptionId
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

RCT_EXPORT_METHOD(sessionPushAudio:(nonnull NSNumber *)sessionId
                  pcmBase64:(NSString *)pcmBase64
                  sampleRate:(nonnull NSNumber *)sampleRate
                  channels:(nonnull NSNumber *)channels
                  isFinal:(BOOL)isFinal) {
  @throw [NSException exceptionWithName:@"FoundryLocalNotImplemented"
                                 reason:@"iOS native implementation not yet wired"
                               userInfo:nil];
}

RCT_REMAP_METHOD(sessionEmbed,
                 sessionEmbedWithId:(nonnull NSNumber *)sessionId
                 requestJson:(NSString *)requestJson
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  FLMReject(reject);
}

#pragma mark - Subscription lifecycle

RCT_EXPORT_METHOD(cancelSubscription:(NSString *)subscriptionId) {
  // Intentionally silent: cancelling an unwired subscription is a no-op.
}

// NativeEventEmitter requires these on every module that emits events.
RCT_EXPORT_METHOD(addListener:(NSString *)eventName) {}
RCT_EXPORT_METHOD(removeListeners:(nonnull NSNumber *)count) {}

@end
