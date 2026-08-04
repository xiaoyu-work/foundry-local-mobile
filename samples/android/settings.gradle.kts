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

rootProject.name = "foundry-local-mobile-samples"

// Compose the Android binding into this build so `implementation("com.microsoft.ai.foundry.local:foundry-local-mobile")`
// in :app substitutes to the sibling project rather than trying to resolve from a
// Maven repository we have not published to. A real consumer would drop the
// includeBuild and add the same coordinate straight from Maven Central.
includeBuild("../../bindings/android") {
    dependencySubstitution {
        substitute(module("com.microsoft.ai.foundry.local:foundry-local-mobile"))
            .using(project(":"))
    }
}

include(":app")
