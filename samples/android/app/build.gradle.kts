// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// Read the model source URL and optional bearer token from local.properties
// (git-ignored) so a developer can point the sample at their own endpoint
// without touching source and without checking in a credential.
val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val defaultModelName: String = localProps.getProperty("flm.sample.modelName", "")
val defaultModelUrl: String = localProps.getProperty("flm.sample.modelUrl", "")
val defaultAuthHeader: String = localProps.getProperty("flm.sample.authHeader", "")

android {
    namespace = "com.microsoft.ai.foundry.local.samples"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.microsoft.ai.foundry.local.samples"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        // Ship only the ABIs the binding builds. Otherwise transitive AndroidX
        // native libraries slip x86 into the APK and Android's install-time
        // ABI matcher rejects the app on an x86 device that has no matching
        // libfoundry_local_mobile.so.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }

        // Non-secret defaults for local.properties keys. A developer who does
        // not want to type in the URL and header every launch can drop them in
        // there; empty defaults mean the app starts on the "please configure"
        // screen instead of trying to hit an unset URL.
        buildConfigField("String", "DEFAULT_MODEL_NAME", "\"${defaultModelName}\"")
        buildConfigField("String", "DEFAULT_MODEL_URL",  "\"${defaultModelUrl}\"")
        buildConfigField("String", "DEFAULT_AUTH_HEADER","\"${defaultAuthHeader}\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }
}

dependencies {
    // Substituted by settings.gradle.kts to the sibling ":bindings-android"
    // project. A published release uses the same coordinate.
    implementation("com.microsoft.ai.foundry.local:foundry-local-mobile")

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")

    val composeBom = platform("androidx.compose:compose-bom:2024.09.03")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
