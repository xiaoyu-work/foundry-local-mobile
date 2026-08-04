// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

// The Android module is the root project: `build.gradle.kts` alongside this
// file applies com.android.library directly. An earlier iteration also
// `include`-d ":foundry-local-mobile" pointed at the same directory, which
// Gradle rejects as two projects sharing one project directory.
rootProject.name = "foundry-local-mobile"

