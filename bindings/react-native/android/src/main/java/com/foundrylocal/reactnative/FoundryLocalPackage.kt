// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

package com.foundrylocal.reactnative

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

/**
 * Autolinking entry point for the Foundry Local TurboModule.
 */
public class FoundryLocalPackage : BaseReactPackage() {
    override fun getModule(
        name: String,
        reactContext: ReactApplicationContext,
    ): NativeModule? =
        if (name == FoundryLocalModule.NAME) {
            FoundryLocalModule(reactContext)
        } else {
            null
        }

    override fun getReactModuleInfoProvider(): ReactModuleInfoProvider =
        ReactModuleInfoProvider {
            mapOf(
                FoundryLocalModule.NAME to ReactModuleInfo(
                    FoundryLocalModule.NAME,
                    FoundryLocalModule::class.java.name,
                    false,
                    false,
                    false,
                    true,
                )
            )
        }
}
