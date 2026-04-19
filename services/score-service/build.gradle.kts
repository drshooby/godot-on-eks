plugins {
    groovy
    alias(libs.plugins.shadow)
    application
}

group = "com.fps"
version = "0.1.0"

dependencies {
    implementation(libs.groovy.core)
    implementation(libs.groovy.json)
    implementation(libs.spark.core)
    implementation(libs.mysql.connector)
    implementation(libs.hikari)
    implementation(libs.jwt)
    implementation(libs.slf4j.simple)
}

application {
    mainClass.set("com.fps.score.Main")
}

tasks.shadowJar {
    archiveBaseName.set("score-service")
    archiveClassifier.set("")
    archiveVersion.set("")
    mergeServiceFiles()
}

tasks.build {
    dependsOn(tasks.shadowJar)
}
