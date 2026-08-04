// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.foundrylocal.reactnative

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Maps between the JS-visible numeric slot ids and the Kotlin objects behind
 * them.
 *
 * The registry is per-module (owned by [FoundryLocalModule]) so tearing the
 * module down releases every native handle without leaving zombie entries in
 * a process-wide table. Slot ids start at 1 so `0` remains reserved as an
 * "invalid handle" sentinel, matching `FLM_INVALID_HANDLE`.
 */
internal class HandleRegistry<T : Any> {
    private val slots = ConcurrentHashMap<Int, T>()
    private val nextSlot = AtomicInteger(1)

    fun register(value: T): Int {
        val id = nextSlot.getAndIncrement()
        slots[id] = value
        return id
    }

    /** Look up the object for [id], or `null` if it has been released. */
    fun get(id: Int): T? = slots[id]

    /** Fetch or throw with a caller-facing message. */
    fun require(id: Int, kind: String): T =
        get(id) ?: throw IllegalStateException("$kind handle $id has been released")

    /** Remove and return the object, or `null` if it was already gone. */
    fun release(id: Int): T? = slots.remove(id)

    /** Release everything. Called when the module tears down. */
    fun releaseAll(): List<T> {
        val all = ArrayList(slots.values)
        slots.clear()
        return all
    }
}
