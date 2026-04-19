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
