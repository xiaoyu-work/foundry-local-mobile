# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

# R8 strips classes that appear unused from the JVM's point of view — but the JNI
# layer looks classes and methods up by name at runtime, so anything the native
# code touches must be kept. These rules are consumed by every app that includes
# this AAR, so an app that turns on minification does not have to know about them.

# Public API surface — apps write against these types directly.
-keep class com.microsoft.ai.foundry.local.mobile.** { *; }

# Callback classes that native code instantiates or invokes reflectively.
-keep class com.microsoft.ai.foundry.local.mobile.internal.NativeCallbacks { *; }
-keep class com.microsoft.ai.foundry.local.mobile.internal.NativeCallbacks$* { *; }
-keep class com.microsoft.ai.foundry.local.mobile.internal.NativeBridge { *; }
-keep class com.microsoft.ai.foundry.local.mobile.internal.NativeProgress { *; }
-keep class com.microsoft.ai.foundry.local.mobile.internal.NativeDelta { *; }

# Keep all @JvmStatic and native methods on the bridge.
-keepclassmembers class * {
    native <methods>;
}

# kotlinx.serialization uses the generated $$serializer classes reflectively at runtime.
-keepattributes InnerClasses
-keepattributes Signature
-keepclassmembers class ** {
    *** Companion;
}
-keepclasseswithmembers class ** {
    kotlinx.serialization.KSerializer serializer(...);
}
