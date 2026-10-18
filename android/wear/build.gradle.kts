plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "app.brege.wear"
    compileSdk = 37

    defaultConfig {
        // The same id and signature as the phone app: that is what lets the two halves find each
        // other over the Data Layer.
        applicationId = "app.brege"
        minSdk = 30
        targetSdk = 34
        versionCode = 2
        versionName = "1.0 beta"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.wear.compose.material)
    implementation(libs.wear.compose.foundation)
    implementation(libs.wear.tiles)
    implementation(libs.wear.protolayout)
    implementation(libs.wear.protolayout.material)
    implementation(libs.play.wearable)
    implementation(libs.kotlinx.coroutines.android)
    // Tiles answer with a ListenableFuture.
    implementation("com.google.guava:guava:33.5.0-android")
}
