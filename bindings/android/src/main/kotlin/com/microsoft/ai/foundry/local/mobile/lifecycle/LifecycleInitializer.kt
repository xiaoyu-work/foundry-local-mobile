// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.microsoft.ai.foundry.local.mobile.lifecycle

import android.content.Context
import androidx.startup.Initializer

/**
 * AndroidX Startup entry point that constructs the [LifecycleBridge]
 * singleton on process start.
 *
 * The bridge is created eagerly rather than lazily so that
 * `FoundryLocal.create` never has to touch `ProcessLifecycleOwner` from a
 * potentially non-main thread — an off-main-thread first access is an
 * IllegalStateException on ProcessLifecycleOwner. The initializer runs on
 * the main thread by contract.
 *
 * Apps that do not want auto-registration can disable it in their manifest:
 *
 * ```xml
 * <provider android:name="androidx.startup.InitializationProvider" ...>
 *   <meta-data android:name="com.microsoft.ai.foundry.local.mobile.lifecycle.LifecycleInitializer"
 *              tools:node="remove" />
 * </provider>
 * ```
 */
public class LifecycleInitializer : Initializer<LifecycleBridge> {
    override fun create(context: Context): LifecycleBridge {
        // Force the ProcessLifecycleOwner initializer to run first, since we
        // observe it inside LifecycleBridge.ensureStarted().
        return LifecycleBridge.forContext(context)!!
    }

    override fun dependencies(): List<Class<out Initializer<*>>> = listOf(
        androidx.lifecycle.ProcessLifecycleInitializer::class.java,
    )
}
