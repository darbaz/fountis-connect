import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.dokka")
    id("maven-publish")
    id("signing")
}

group = "org.fountis"
version = "1.1.0"

android {
    namespace = "org.fountis.connect"
    compileSdk = 36

    defaultConfig {
        minSdk = 23
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    lint {
        abortOnError = false
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
            // The javadoc jar Maven Central requires is built from Dokka below (AGP's own only reads Java sources).
        }
    }
}

kotlin {
    explicitApi()
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_1_8)
        // Friendly to consumers on older Kotlin compilers.
        languageVersion.set(KotlinVersion.KOTLIN_1_9)
        apiVersion.set(KotlinVersion.KOTLIN_1_9)
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    implementation("androidx.webkit:webkit:1.12.1")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    // Device attestation for guests (Standard API). Only started for an app whose attestation mode is report or enforce.
    // If you change this version, change it in react-native/android/build.gradle and flutter/fountis_connect_mobile/android/build.gradle too.
    implementation("com.google.android.play:integrity:1.6.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

// ---- Publishing (Maven Central) -------------------------------------------------------------------
// Coordinates: org.fountis:connect:<version>. Nothing here publishes by itself: `publishToMavenLocal` works
// without any secret, and the Central repository below is only added when credentials are supplied.
// Credentials and the signing key come ONLY from Gradle properties or environment variables:
//   mavenCentralUsername / mavenCentralPassword   (env MAVEN_CENTRAL_USERNAME / MAVEN_CENTRAL_PASSWORD)  Central Portal user token
//   signingKey / signingPassword                  (env SIGNING_KEY / SIGNING_PASSWORD)                    ASCII-armored GPG private key
fun secret(property: String, env: String): String? =
    (findProperty(property) as String?)?.takeIf { it.isNotBlank() } ?: System.getenv(env)?.takeIf { it.isNotBlank() }

val dokkaJavadocJar by tasks.registering(Jar::class) {
    description = "Javadoc jar (Dokka) for Maven Central"
    group = "documentation"
    archiveClassifier.set("javadoc")
    val dokka = tasks.named<org.jetbrains.dokka.gradle.DokkaTask>("dokkaJavadoc")
    dependsOn(dokka)
    from(dokka.flatMap { it.outputDirectory })
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = "org.fountis"
                artifactId = "connect"
                version = project.version.toString()
                artifact(dokkaJavadocJar)

                pom {
                    name.set("FOUNTIS Connect")
                    description.set(
                        "FOUNTIS Connect Android SDK: shows partner users a short research study from FOUNTIS inside the partner app."
                    )
                    url.set("https://github.com/darbaz/fountis-connect")
                    licenses {
                        license {
                            name.set("FOUNTIS Connect SDK License")
                            url.set("https://github.com/darbaz/fountis-connect/blob/main/android/LICENSE")
                            distribution.set("repo")
                        }
                    }
                    developers {
                        developer {
                            id.set("fountis")
                            name.set("FOUNTIS")
                            email.set("dev@fountis.org")
                            organization.set("FOUNTIS")
                            organizationUrl.set("https://fountis.org")
                        }
                    }
                    scm {
                        url.set("https://github.com/darbaz/fountis-connect")
                        connection.set("scm:git:https://github.com/darbaz/fountis-connect.git")
                        developerConnection.set("scm:git:ssh://git@github.com/darbaz/fountis-connect.git")
                    }
                }
            }
        }

        val centralUser = secret("mavenCentralUsername", "MAVEN_CENTRAL_USERNAME")
        val centralPassword = secret("mavenCentralPassword", "MAVEN_CENTRAL_PASSWORD")
        if (centralUser != null && centralPassword != null) {
            repositories {
                maven {
                    name = "central"
                    // Central Portal's OSSRH-compatible staging endpoint. After the upload, the release workflow moves the
                    // deployment into the Portal, where the owner presses Publish.
                    url = uri("https://ossrh-staging-api.central.sonatype.com/service/local/staging/deploy/maven2/")
                    credentials {
                        username = centralUser
                        password = centralPassword
                    }
                }
            }
        }
    }

    signing {
        val key = secret("signingKey", "SIGNING_KEY")
        val password = secret("signingPassword", "SIGNING_PASSWORD")
        // Sign only when a key is supplied, so local builds and dry runs need no GPG setup.
        isRequired = false
        if (key != null) {
            useInMemoryPgpKeys(key, password)
            sign(publishing.publications["release"])
        }
    }
}
