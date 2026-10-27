import java.time.Duration
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Every build gets a newer versionCode (minutes since 2026) and a visible build time,
// so you can tell on the phone that an update actually landed.
val buildTime: LocalDateTime = LocalDateTime.now()

android {
    namespace = "dev.longarm"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.longarm"
        minSdk = 26
        targetSdk = 36
        versionCode = Duration.between(LocalDateTime.of(2026, 1, 1, 0, 0), buildTime).toMinutes().toInt()
        versionName = "0.1.0"
        // WebRTC's native code for phones (and the x86_64 emulator); 32-bit x86 isn't worth the size.
        // -Pabis=arm64-v8a builds for current phones only, for a smaller APK to share.
        ndk {
            abiFilters += (project.findProperty("abis") as String?)?.split(",")
                ?: listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
        buildConfigField(
            "String", "BUILD_TIME",
            "\"${buildTime.format(DateTimeFormatter.ofPattern("d MMM HH:mm", Locale.ENGLISH))}\"",
        )
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("io.github.webrtc-sdk:android:150.7871.01")   // Google's WebRTC, as built by LiveKit
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // QR scanning UI provided by Google Play services: no camera permission needed.
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
}
