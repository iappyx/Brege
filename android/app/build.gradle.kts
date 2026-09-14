plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "app.brege"
    compileSdk = 37
    buildToolsVersion = "36.0.0"
    ndkVersion = "30.0.16248370"

    defaultConfig {
        applicationId = "app.brege"
        minSdk = 29
        targetSdk = 36
        versionCode = 2
        versionName = "1.0 beta"
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    packaging {
        jniLibs {
            // Store native libraries uncompressed and page-aligned (16 KB page sizes).
            useLegacyPackaging = false
        }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.service)
    implementation(libs.androidx.work.runtime)
    implementation(libs.androidx.fragment)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.material3)
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material.icons)
    implementation(libs.play.code.scanner)
    implementation(libs.play.document.scanner)
    implementation(libs.kotlinx.coroutines.android)
    // UniFFI's Kotlin bindings load the Rust library through JNA.
    implementation("${libs.jna.get().module}:${libs.jna.get().version}@aar")
}
