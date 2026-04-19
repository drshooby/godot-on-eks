pluginManagement {
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}

rootProject.name = "fps-godot-on-eks"

listOf("auth-service", "score-service", "session-service").forEach { name ->
    include(":$name")
    project(":$name").projectDir = file("services/$name")
}
