// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Base class for every error that reaches an app from the Foundry Local Mobile
 * SDK.
 *
 * Instances carry the raw [detailJson] payload the ABI produced, so an app
 * that wants machine-readable context (HTTP status codes, missing model ids,
 * checksum failures) can access it without parsing the message. [isRetryable]
 * mirrors the `"retryable"` flag the core sets for transient failures.
 *
 * A native call that returns an OK status never raises this exception; a call
 * that fails always does — never a bare [RuntimeException].
 */
public open class FoundryLocalException @JvmOverloads constructor(
    /** Numeric ABI status. Corresponds to `flm_status`. */
    public val status: Int,
    message: String?,
    /** Machine-readable detail JSON returned by `flm_last_error_detail_json`. */
    public val detailJson: String? = null,
    cause: Throwable? = null,
) : RuntimeException(message ?: statusName(status), cause) {

    /** Same message as [message], never null. */
    public val messageOrEmpty: String get() = message.orEmpty()

    /**
     * Whether the core flagged this failure as retryable. Callers should not
     * retry indefinitely — the flag captures whether the *class* of error can
     * succeed on a subsequent attempt (transient network failure, transient
     * storage failure) rather than whether *this* attempt should be repeated.
     */
    public val isRetryable: Boolean by lazy { parseRetryable(detailJson) }

    /** Optional context object from the detail JSON, e.g. `{ "url": ..., "http_status": ... }`. */
    public val context: JsonObject? by lazy { parseContext(detailJson) }

    public companion object {
        /**
         * Build the correct concrete subclass for [status]. Returns
         * [FoundryLocalException] for FLM_OK, because raising success is a
         * caller bug.
         */
        @JvmStatic
        public fun fromStatus(
            status: Int,
            message: String?,
            detailJson: String?,
        ): FoundryLocalException = when (status) {
            2 -> InvalidArgumentException(status, message, detailJson)
            3 -> InvalidHandleException(status, message, detailJson)
            4 -> InvalidStateException(status, message, detailJson)
            5 -> NotFoundException(status, message, detailJson)
            6 -> NotImplementedException(status, message, detailJson)
            7 -> CancelledException(status, message, detailJson)
            8 -> NetworkException(status, message, detailJson)
            9 -> StorageException(status, message, detailJson)
            10 -> OutOfMemoryException(status, message, detailJson)
            11 -> IncompatibleException(status, message, detailJson)
            12 -> TimeoutException(status, message, detailJson)
            13 -> UnsupportedVersionException(status, message, detailJson)
            14 -> MemoryPressureException(status, message, detailJson)
            15 -> ShutdownException(status, message, detailJson)
            else -> InternalException(status, message, detailJson)
        }

        private val json = Json { ignoreUnknownKeys = true }

        private fun parseRetryable(detailJson: String?): Boolean {
            if (detailJson.isNullOrEmpty()) return false
            return runCatching {
                val obj = json.parseToJsonElement(detailJson).jsonObject
                obj["retryable"]?.jsonPrimitive?.content?.equals("true", ignoreCase = true) == true
            }.getOrDefault(false)
        }

        private fun parseContext(detailJson: String?): JsonObject? {
            if (detailJson.isNullOrEmpty()) return null
            return runCatching {
                val obj = json.parseToJsonElement(detailJson).jsonObject
                obj["context"] as? JsonObject
            }.getOrNull()
        }

        private fun statusName(status: Int): String = when (status) {
            0 -> "OK"
            1 -> "INTERNAL"
            2 -> "INVALID_ARGUMENT"
            3 -> "INVALID_HANDLE"
            4 -> "INVALID_STATE"
            5 -> "NOT_FOUND"
            6 -> "NOT_IMPLEMENTED"
            7 -> "CANCELLED"
            8 -> "NETWORK"
            9 -> "STORAGE"
            10 -> "OUT_OF_MEMORY"
            11 -> "INCOMPATIBLE"
            12 -> "TIMEOUT"
            13 -> "UNSUPPORTED_VERSION"
            14 -> "MEMORY_PRESSURE"
            15 -> "SHUTDOWN"
            else -> "STATUS_$status"
        }
    }
}

public class InternalException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class InvalidArgumentException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class InvalidHandleException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class InvalidStateException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class NotFoundException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class NotImplementedException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class CancelledException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class NetworkException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class StorageException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class OutOfMemoryException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class IncompatibleException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class TimeoutException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class UnsupportedVersionException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class MemoryPressureException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)

public class ShutdownException internal constructor(status: Int, message: String?, detailJson: String?) :
    FoundryLocalException(status, message, detailJson)
