import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "app.unifiedslicer.companion"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.unifiedslicer.companion"
        minSdk = 26
        targetSdk = 36
        versionCode = 4
        versionName = "1.3.0"
        // The Elegoo messaging SDK ships native code; phones are ARM.
        ndk { abiFilters += setOf("arm64-v8a", "armeabi-v7a") }
    }

    // Release signing key comes from the environment (CI secrets), never from the repository:
    // COMPANION_KEYSTORE (path to the .jks/.keystore), COMPANION_KEYSTORE_PASSWORD,
    // COMPANION_KEY_ALIAS, COMPANION_KEY_PASSWORD (defaults to the store password).
    // Without them the build is signed with the local debug key, which cannot update an
    // installed release build.
    val releaseKeystore = System.getenv("COMPANION_KEYSTORE")?.takeIf { it.isNotBlank() }?.let(::file)
    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = System.getenv("COMPANION_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("COMPANION_KEY_ALIAS") ?: "companion"
                keyPassword = System.getenv("COMPANION_KEY_PASSWORD") ?: System.getenv("COMPANION_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = if (releaseKeystore != null) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures { compose = true }

    packaging {
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "META-INF/versions/9/previous-compilation-data.bin")
    }
}

kotlin { compilerOptions { jvmTarget.set(JvmTarget.JVM_17) } }

dependencies {
    implementation(project(":core"))
    implementation(libs.coroutines.android)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.work)
    implementation(libs.androidx.webkit)
    implementation(libs.agora.rtm)
    implementation(libs.androidx.media3.exoplayer)
    implementation(libs.androidx.media3.rtsp)
    implementation(libs.androidx.media3.ui)
    implementation(libs.zxing.embedded)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.icons)
    debugImplementation(libs.compose.ui.tooling)
}
