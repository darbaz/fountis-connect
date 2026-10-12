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

rootProject.name = "fountis-connect-android"

include(":connect")
// The sample lives next to the other samples; it is built with this same Gradle build.
include(":sample")
project(":sample").projectDir = file("../samples/android/app")
