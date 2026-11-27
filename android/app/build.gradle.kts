import java.net.URI
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningPropertiesFile = rootProject.file("key.properties")
val releaseSigningProperties = Properties()
val releaseSigningReadFailed = try {
    if (releaseSigningPropertiesFile.isFile) {
        releaseSigningPropertiesFile.inputStream().use { releaseSigningProperties.load(it) }
    }
    false
} catch (_: Exception) {
    // A damaged/unreadable release-only file must not block debug builds or
    // expose credential values through a configuration-time parsing error.
    releaseSigningProperties.clear()
    true
}
var releaseKeystorePathInvalid = false
val releaseKeystoreFile = try {
    releaseSigningProperties.getProperty("storeFile")
        ?.takeIf { it.isNotBlank() }
        ?.let { file(it) }
} catch (_: Exception) {
    releaseKeystorePathInvalid = true
    null
}
val encodedDartDefines = providers.gradleProperty("dart-defines")

val validateReleaseConfiguration = tasks.register("validateReleaseConfiguration") {
    group = "verification"
    description = "Require upload signing and published privacy details before building a release."
    doLast {
        if (releaseSigningReadFailed) {
            throw GradleException(
                "Release signing configuration could not be read. Check the format and read " +
                    "permissions of android/key.properties."
            )
        }
        val missingSigningProperties = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
            .filter { releaseSigningProperties.getProperty(it).isNullOrBlank() }
        if (missingSigningProperties.isNotEmpty()) {
            throw GradleException(
                "Release signing is not configured. Copy android/key.properties.example to " +
                    "android/key.properties and set storeFile, storePassword, keyAlias and keyPassword " +
                    "for your upload keystore. Release builds never use the debug signing key."
            )
        }
        val keystoreExists = try {
            releaseKeystoreFile?.isFile == true
        } catch (_: Exception) {
            false
        }
        if (releaseKeystorePathInvalid || !keystoreExists) {
            throw GradleException(
                "Release signing storeFile must point to an existing upload keystore. " +
                    "A relative storeFile path is resolved from android/app."
            )
        }

        val dartDefines = try {
            encodedDartDefines.orNull.orEmpty().split(',')
                .filter { it.isNotEmpty() }
                .associate { encoded ->
                    val decoded = String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
                    val separator = decoded.indexOf('=')
                    require(separator > 0)
                    decoded.substring(0, separator) to decoded.substring(separator + 1)
                }
        } catch (_: IllegalArgumentException) {
            // Do not include encoded/decoded definitions: they may contain secrets.
            throw GradleException("Invalid Dart defines. Pass release settings with Flutter --dart-define.")
        }
        val publisher = dartDefines["PRIVACY_PUBLISHER_NAME"].orEmpty().trim()
        val contact = dartDefines["PRIVACY_CONTACT_EMAIL"].orEmpty().trim()
        val policyUrl = dartDefines["PRIVACY_POLICY_URL"].orEmpty().trim()
        val validContact = Regex("""^[^\s@]+@[^\s@]+\.[^\s@]+$""").matches(contact)
        val validPolicyUrl = try {
            URI(policyUrl).let {
                it.scheme.equals("https", ignoreCase = true) &&
                    !it.host.isNullOrBlank() && it.userInfo == null
            }
        } catch (_: java.net.URISyntaxException) {
            false
        }
        if (publisher.isEmpty() || !validContact || !validPolicyUrl) {
            throw GradleException(
                "Release privacy details are missing or invalid. Supply --dart-define values for " +
                    "PRIVACY_PUBLISHER_NAME (nonempty publisher), PRIVACY_CONTACT_EMAIL " +
                    "(valid contact email) and PRIVACY_POLICY_URL (public HTTPS policy URL)."
            )
        }
    }
}

tasks.configureEach {
    if (name.contains("Release") && name != validateReleaseConfiguration.name) {
        dependsOn(validateReleaseConfiguration)
    }
}

android {
    namespace = "com.termpulse.termpulse"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.termpulse.termpulse"
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = releaseKeystoreFile
            storePassword = releaseSigningProperties.getProperty("storePassword")
            keyAlias = releaseSigningProperties.getProperty("keyAlias")
            keyPassword = releaseSigningProperties.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.github.mik3y:usb-serial-for-android:3.10.0")
}
