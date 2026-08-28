// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.internal

/**
 * Direct 1:1 wrapper over `flm_*` JNI entry points.
 */
internal object NativeBridge {
    init {
        System.loadLibrary("foundry_local_mobile")
        System.loadLibrary("foundry_local_mobile_jni")
    }

    // --- Library-wide ----------------------------------------------------

    @JvmStatic external fun versionString(): String
    @JvmStatic external fun apiVersion(): Int
    @JvmStatic external fun runtimeVersionString(): String?
    @JvmStatic external fun isRuntimeAvailable(): Boolean
    @JvmStatic external fun setLogLevel(level: Int): Int

    @JvmStatic external fun lastErrorMessage(): String
    @JvmStatic external fun lastErrorDetailJson(): String
    @JvmStatic external fun clearLastError()

    // --- Manager ---------------------------------------------------------

    @JvmStatic external fun managerCreate(configJson: String): Long
    @JvmStatic external fun managerShutdown(manager: Long)
    @JvmStatic external fun managerRelease(manager: Long)
    @JvmStatic external fun managerGetDeviceProfileJson(manager: Long): String
    @JvmStatic external fun managerNotifyLifecycle(manager: Long, event: Int)
    @JvmStatic external fun managerUpdateSettings(manager: Long, settingsJson: String)
    @JvmStatic external fun managerLoadModelAsync(
        manager: Long,
        modelPath: String,
        optionsJson: String?,
        correlationId: Long,
    ): Long

    // --- Model -----------------------------------------------------------

    @JvmStatic external fun modelRelease(model: Long)
    @JvmStatic external fun modelGetInfoJson(model: Long): String
    @JvmStatic external fun modelIsCached(model: Long): Boolean
    @JvmStatic external fun modelIsLoaded(model: Long): Boolean
    @JvmStatic external fun modelGetPath(model: Long): String

    @JvmStatic external fun modelLoadAsync(model: Long, optionsJson: String?, correlationId: Long): Long
    @JvmStatic external fun modelUnloadAsync(model: Long, correlationId: Long): Long

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
}
