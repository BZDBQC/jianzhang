plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingStore = System.getenv("JIANZHANG_KEYSTORE_PATH")
val signingPassword = System.getenv("JIANZHANG_KEYSTORE_PASSWORD")
val canSignRelease = !signingStore.isNullOrBlank() && !signingPassword.isNullOrBlank()
if (gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) } && !canSignRelease) {
    throw GradleException("Release signing is required. Build with scripts/native-toolchain/build-android.ps1.")
}

android {
    namespace = "com.jianzhang.ledger"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.jianzhang.ledger"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (canSignRelease) {
            create("release") {
                storeFile = file(signingStore!!)
                storePassword = signingPassword
                keyAlias = "jianzhang-release"
                keyPassword = signingPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (canSignRelease) signingConfigs.getByName("release") else null
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
