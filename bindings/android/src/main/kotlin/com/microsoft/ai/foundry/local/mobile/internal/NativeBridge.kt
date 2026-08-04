// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.internal

/**
 * Direct 1:1 wrapper over `flm_*` JNI entry points.
 *
 * This class is deliberately internal: the public Kotlin API sits on top of it
 * and translates the C ABI's handle-plus-JSON conventions into idiomatic Kotlin.
 * Do not add convenience methods here — they belong in the layer above.
 *
 * ### Threading
 *
 * Every method that returns a job handle (`jobFoo`, `nativeXxxAsync`) starts the
 * work on a core thread and returns immediately. The completion arrives on a
 * [NativeCallbacks] entry, on a JVM-attached core thread. Callers must marshal
 * to their preferred dispatcher.
 *
 * ### Handles
 *
 * All handles are Java longs, mapped to `flm_handle` (uint64) on the C side.
 * `0L` is `FLM_INVALID_HANDLE` and never a valid handle.
 */
internal object NativeBridge {
    init {
        // The core is loaded first because the JNI wrapper links against it;
        // System.loadLibrary handles transitive deps via the app's native
        // library directory, but the explicit ordering keeps failures readable.
        System.loadLibrary("foundry_local_mobile")
        System.loadLibrary("foundry_local_mobile_jni")
    }

    // --- Library-wide ----------------------------------------------------

    @JvmStatic external fun versionString(): String
    @JvmStatic external fun apiVersion(): Int
    @JvmStatic external fun runtimeVersionString(): String?
    @JvmStatic external fun isRuntimeAvailable(): Boolean
    @JvmStatic external fun setRuntimeLibraryPath(path: String?): Int
    @JvmStatic external fun setLogLevel(level: Int): Int

    @JvmStatic external fun lastErrorMessage(): String
    @JvmStatic external fun lastErrorDetailJson(): String
    @JvmStatic external fun clearLastError()

    // --- Manager ---------------------------------------------------------

    @JvmStatic external fun managerCreate(configJson: String): Long
    @JvmStatic external fun managerShutdown(manager: Long)
    @JvmStatic external fun managerRelease(manager: Long)
    @JvmStatic external fun managerGetCatalog(manager: Long): Long
    @JvmStatic external fun managerGetDeviceProfileJson(manager: Long): String
    @JvmStatic external fun managerNotifyLifecycle(manager: Long, event: Int)
    @JvmStatic external fun managerUpdateSettings(manager: Long, settingsJson: String)
    @JvmStatic external fun managerAddModelSourceAsync(
        manager: Long,
        sourceJson: String,
        correlationId: Long,
    ): Long

    // --- Catalog ---------------------------------------------------------

    @JvmStatic external fun catalogListModelsAsync(
        catalog: Long,
        filterJson: String?,
        correlationId: Long,
    ): Long

    @JvmStatic external fun catalogGetModelAsync(
        catalog: Long,
        alias: String,
        correlationId: Long,
    ): Long

    @JvmStatic external fun catalogGetModelByIdAsync(
        catalog: Long,
        modelId: String,
        correlationId: Long,
    ): Long

    @JvmStatic external fun catalogListCachedModelsJson(catalog: Long): String
    @JvmStatic external fun catalogGetCacheSizeBytes(catalog: Long): Long

    // --- Model -----------------------------------------------------------

    @JvmStatic external fun modelRelease(model: Long)
    @JvmStatic external fun modelGetInfoJson(model: Long): String
    @JvmStatic external fun modelIsCached(model: Long): Boolean
    @JvmStatic external fun modelIsLoaded(model: Long): Boolean
    @JvmStatic external fun modelGetPath(model: Long): String

    @JvmStatic external fun modelLoadAsync(model: Long, optionsJson: String?, correlationId: Long): Long
    @JvmStatic external fun modelUnloadAsync(model: Long, correlationId: Long): Long
    @JvmStatic external fun modelDeleteAsync(model: Long, correlationId: Long): Long

    @JvmStatic external fun modelIsPackage(model: Long): Boolean
    @JvmStatic external fun packageGetVariantsJson(model: Long): String
    @JvmStatic external fun packageSelectVariant(model: Long, variantId: String)
    @JvmStatic external fun packageSelectBestVariant(model: Long, constraintsJson: String?): String
    @JvmStatic external fun packageGetVariant(model: Long, variantId: String): Long
    @JvmStatic external fun packageEstimateDownloadJson(model: Long, variantIdsJson: String?): String

    // --- Sessions --------------------------------------------------------

    @JvmStatic external fun sessionCreate(model: Long, optionsJson: String?): Long
    @JvmStatic external fun sessionRelease(session: Long)
    @JvmStatic external fun sessionSetOptions(session: Long, optionsJson: String)

    @JvmStatic external fun sessionCompleteAsync(
        session: Long,
        requestJson: String,
        streaming: Boolean,
        correlationId: Long,
    ): Long

    @JvmStatic external fun sessionSubmitToolResultsAsync(
        session: Long,
        toolResultsJson: String,
        streaming: Boolean,
        correlationId: Long,
    ): Long

    @JvmStatic external fun sessionTranscribeAsync(
        session: Long,
        requestJson: String,
        streaming: Boolean,
        correlationId: Long,
    ): Long

    @JvmStatic external fun sessionPushAudio(
        session: Long,
        pcm: ByteArray,
        sampleRate: Int,
        channels: Int,
        isFinal: Boolean,
    )

    @JvmStatic external fun sessionEmbedAsync(
        session: Long,
        requestJson: String,
        correlationId: Long,
    ): Long

    @JvmStatic external fun sessionGetTurnCount(session: Long): Long
    @JvmStatic external fun sessionUndoTurns(session: Long, count: Long)
    @JvmStatic external fun sessionClearHistory(session: Long)
    @JvmStatic external fun sessionExportHistoryJson(session: Long): String
    @JvmStatic external fun sessionRestoreHistoryJson(session: Long, historyJson: String)

    // --- Jobs ------------------------------------------------------------

    @JvmStatic external fun jobGetState(job: Long): Int
    @JvmStatic external fun jobCancel(job: Long)
    @JvmStatic external fun jobTakeResultJson(job: Long): String?
    @JvmStatic external fun jobRelease(job: Long)

    // --- Transport -------------------------------------------------------

    @JvmStatic external fun installDefaultTransport()
    @JvmStatic external fun uninstallTransport()

    @JvmStatic external fun transportReportProgress(requestId: Long, completedBytes: Long, totalBytes: Long)
    @JvmStatic external fun transportReportBody(requestId: Long, data: ByteArray)
    @JvmStatic external fun transportReportComplete(
        requestId: Long,
        statusCode: Int,
        headersJson: String?,
        errorMessage: String?,
    )
}
