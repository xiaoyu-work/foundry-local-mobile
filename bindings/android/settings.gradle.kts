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

rootProject.name = "foundry-local-mobile-android"

include(":foundry-local-mobile")
project(":foundry-local-mobile").projectDir = file("./")
