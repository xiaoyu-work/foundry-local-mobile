// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

plugins {
    id("com.android.library") version "8.5.2"
    id("org.jetbrains.kotlin.android") version "2.0.20"
    id("org.jetbrains.kotlin.plugin.serialization") version "2.0.20"
    `maven-publish`
}

group = "com.microsoft.ai.foundry.local"
version = project.findProperty("version")?.toString()?.takeIf { it != "unspecified" }
    ?: "0.1.0"

android {
    namespace = "com.microsoft.ai.foundry.local.mobile"
    compileSdk = 35
    ndkVersion = "27.0.12077973"

    defaultConfig {
        minSdk = 26

        // Ship arm64-v8a for modern Android hardware, armeabi-v7a for legacy 32-bit
        // devices that make up a shrinking but non-zero share of the install base, and
        // x86_64 so the SDK runs in the Android Studio emulator during development.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }

        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++20", "-fvisibility=hidden", "-fvisibility-inlines-hidden")
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
                    "-DFLM_BUILD_SHARED=ON",
                    "-DFLM_BUILD_EXAMPLES=OFF",
                    // 16 KB page alignment is enforced on Android 15+ arm64.
                    "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON"
                )
            }
        }

        consumerProguardFiles("consumer-rules.pro")
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packaging {
        // Merge the C++ shared runtime that ships with each ABI slice.
        jniLibs {
            useLegacyPackaging = false
            pickFirsts += listOf("**/libc++_shared.so")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
        freeCompilerArgs += listOf(
            "-Xjvm-default=all",
            // Consumers opt-in to internal experimental APIs individually.
            "-opt-in=kotlinx.coroutines.ExperimentalCoroutinesApi"
        )
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            consumerProguardFiles("consumer-rules.pro")
        }
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

dependencies {
    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    // OkHttp powers the default HTTP transport. Apps that install a custom transport
    // still pull it in transitively, which is why it is 'api' rather than 'implementation'.
    api("com.squareup.okhttp3:okhttp:4.12.0")

    implementation("androidx.annotation:annotation:1.8.2")
    implementation("androidx.lifecycle:lifecycle-process:2.8.6")
    implementation("androidx.lifecycle:lifecycle-common:2.8.6")
    implementation("androidx.startup:startup-runtime:1.2.0")

    // WorkManager backs the resumable/background download variant of the transport.
    implementation("androidx.work:work-runtime-ktx:2.9.1")
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = project.group.toString()
            artifactId = "foundry-local-mobile"
            version = project.version.toString()

            afterEvaluate {
                from(components["release"])
            }

            pom {
                name.set("Foundry Local Mobile")
                description.set("Android SDK for Microsoft Foundry Local on-device AI inference.")
                url.set("https://github.com/microsoft/foundry-local-mobile")
                licenses {
                    license {
                        name.set("MIT")
                        url.set("https://opensource.org/licenses/MIT")
                    }
                }
            }
        }
    }
}
