plugins {
    scala
    alias(libs.plugins.shadow)
    application
}

group = "com.fps"
version = "0.1.0"

dependencies {
    implementation("org.scala-lang:scala3-library_3:3.3.4")
    implementation("com.google.code.gson:gson:2.11.0")
    implementation(libs.spark.core)
    implementation(libs.mysql.connector)
    implementation(libs.hikari)
    implementation(libs.jwt)
    implementation(libs.slf4j.simple)
}

application {
    mainClass.set("com.fps.session.Main")
}

tasks.withType<ScalaCompile>().configureEach {
    scalaCompileOptions.additionalParameters.addAll(listOf("-release", "21"))
}

tasks.shadowJar {
    archiveBaseName.set("session-service")
    archiveClassifier.set("")
    archiveVersion.set("")
    mergeServiceFiles()
}

tasks.build {
    dependsOn(tasks.shadowJar)
}
