pluginManagement {
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
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
