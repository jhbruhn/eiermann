import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Where the release signing key comes from ────────────────────────────────
//
// Two sources, checked in this order, because the two callers are different
// people: CI has the key in a secret and a local release build has it in a file
// nobody may commit (`key.properties` and `*.jks` are gitignored).
//
// Env FIRST so a CI run cannot be silently overridden by a `key.properties`
// left behind in a checkout.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

/** Whether a real signing key is available at all. */
val hasReleaseKey =
    System.getenv("ANDROID_KEYSTORE_PATH") != null || keystoreProperties["storeFile"] != null

android {
    namespace = "de.jhbruhn.eiermann"
    // Flutter's own number, which is 36 — the newest STABLE Android platform
    // and AGP 9.0.1's maximum recommended.
    //
    // It stays Flutter's rather than a literal because the one dependency that
    // wanted more is held back instead: `flutter_secure_storage` 11 demands 37,
    // which exists only as a preview platform, and a release built against a
    // preview stops being rebuildable when that preview is withdrawn. See the
    // `dependency_overrides` block in the workspace pubspec for the full
    // reasoning and the way out.
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "de.jhbruhn.eiermann"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // `flutter.versionCode` is the --build-number, and for `--split-per-abi`
        // Flutter OFFSETS it per ABI (armeabi-v7a → 1xxx, arm64-v8a → 2xxx) so
        // the variants stay distinct in a store. See the release workflow: that
        // offset is why an updater's APK filter has to stay on one variant.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val envPath = System.getenv("ANDROID_KEYSTORE_PATH")
            if (envPath != null) {
                storeFile = file(envPath)
                keyAlias = System.getenv("ANDROID_KEYSTORE_ALIAS")
                keyPassword = System.getenv("ANDROID_KEYSTORE_PRIVATE_KEY_PASSWORD")
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            } else {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String?
            }
        }
    }

    buildTypes {
        getByName("release") {
            // The debug key remains the fallback, and that is deliberate rather
            // than lazy: `flutter run --release` on a developer's machine has no
            // keystore and must keep working. What must NOT happen is a release
            // that silently ships debug-signed — an APK signed with the debug
            // key cannot be upgraded over a properly signed install, and the
            // failure lands on the users' phones rather than in the build.
            //
            // So the release workflow verifies the signer after building
            // (`apksigner verify --print-certs`) instead of trusting this line.
            signingConfig =
                if (hasReleaseKey) {
                    signingConfigs.getByName("release")
                } else {
                    logger.lifecycle(
                        "eiermann: no release keystore found — signing with the " +
                            "DEBUG key. Fine for `flutter run --release`, never for " +
                            "anything anybody installs."
                    )
                    signingConfigs.getByName("debug")
                }
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
