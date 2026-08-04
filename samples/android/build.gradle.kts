// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

// Root project of the samples build. All actual work happens in :app; this
// file only exists to declare the plugins that :app applies, keeping their
// versions in one place.

plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.20" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.0.20" apply false
}
