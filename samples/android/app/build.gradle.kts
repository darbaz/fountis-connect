import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Sandbox key: fountis.sandboxKey in samples/android/local.properties (gitignored; run ../setup.sh) or in the
// Gradle root's local.properties. CI builds with a placeholder, which is fine for assembling.
fun localProp(name: String): String? {
    for (f in listOf(file("../local.properties"), rootProject.file("local.properties"))) {
        if (f.exists()) {
            val p = Properties().apply { f.inputStream().use { load(it) } }
            p.getProperty(name)?.let { return it }
        }
    }
    return null
}

android {
    namespace = "org.fountis.connect.sample"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.fountis.connect.sample"
        minSdk = 23
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        buildConfigField("String", "SANDBOX_KEY", "\"${localProp("fountis.sandboxKey") ?: "pk_test_PASTE_YOUR_SANDBOX_KEY"}\"")
        buildConfigField("String", "API_BASE", "\"${localProp("fountis.apiBase") ?: "https://api.fountis.org/connect/v1"}\"")
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
    }
}

dependencies {
    implementation("org.fountis:connect:1.2.0")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
