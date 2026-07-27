plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.mobile"
    // file_picker's plugin chain (flutter_plugin_android_lifecycle) requires
    // compiling against API 36; Flutter's default here is still 34. compileSdk
    // only controls which APIs are available at build time, independent of
    // targetSdk/minSdk, so raising it is safe.
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.mobile"
        // The foreground-service data-sync type and the notification listener
        // both need APIs introduced in 24, so the floor is raised from whatever
        // Flutter defaults to.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // NotificationCompat and the foreground-service helpers used by the Kotlin
    // side. Flutter's own AndroidX transitive versions are not guaranteed, so
    // the one we compile against is pinned explicitly.
    implementation("androidx.core:core-ktx:1.13.1")
}
