import org.gradle.api.plugins.JavaPluginExtension
import org.gradle.jvm.toolchain.JavaLanguageVersion

// Host JDK may be 25+ (Kotlin 2.0 / Groovy 3 cannot compile against it yet). Pin bytecode to 21.
subprojects {
    plugins.withId("java") {
        extensions.configure<JavaPluginExtension>("java") {
            toolchain {
                languageVersion.set(JavaLanguageVersion.of(21))
            }
        }
    }
}

// Root aggregator; per-service jars built in services/*
tasks.register("shadowJars") {
    group = "build"
    description = "Build all service fat jars"
    dependsOn(
        ":auth-service:shadowJar",
        ":score-service:shadowJar",
        ":session-service:shadowJar",
    )
}
