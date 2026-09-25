import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Discord's Social SDK can't be published in this repo, so it's only included when it has been
// unpacked into android/sdk (see android/sdk/README.md). Without it the app builds without linking.
val sdkDir = rootProject.file("sdk")
val hasSdk = sdkDir.resolve("discord_partner_sdk.aar").exists() && sdkDir.resolve("include/discordpp.h").exists()
val discordAppId = providers.gradleProperty("discordAppId").get()

android {
    namespace = "io.github.noice912.richpresence"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.github.noice912.richpresence"
        minSdk = 26
        targetSdk = 35
        versionCode = 3
        versionName = "0.2.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("long", "DISCORD_APP_ID", "${discordAppId}L")
        manifestPlaceholders["discordAppId"] = discordAppId
        manifestPlaceholders["hasDiscordSdk"] = hasSdk.toString()
        if (hasSdk) {
            ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
            externalNativeBuild { cmake { arguments += "-DSDK_DIR=${sdkDir.absolutePath.replace('\\', '/')}" } }
        }
    }

    buildFeatures { buildConfig = true }

    sourceSets["main"].java.srcDir(if (hasSdk) "src/sdk/java" else "src/nosdk/java")
    if (hasSdk) {
        externalNativeBuild { cmake { path = file("src/sdk/cpp/CMakeLists.txt") } }
        // the SDK's .so comes from the .aar; the bridge only links against it
        packaging { jniLibs { pickFirsts += "**/libdiscord_partner_sdk.so" } }
    }

    // The same key must sign every version, or phones refuse the update. CI writes it from secrets;
    // local builds read android/keystore.properties (not in the repo).
    val localKeys = rootProject.file("keystore.properties").takeIf { it.exists() }?.let { f ->
        Properties().apply { f.inputStream().use { load(it) } }
    }
    val keystore = (System.getenv("ANDROID_KEYSTORE_FILE") ?: localKeys?.getProperty("storeFile"))?.let { file(it) }?.takeIf { it.exists() }
    val keyPass = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: localKeys?.getProperty("password")
    val keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: localKeys?.getProperty("alias")
    signingConfigs {
        if (keystore != null) create("release") {
            storeFile = keystore
            storePassword = keyPass
            this.keyAlias = keyAlias
            keyPassword = keyPass
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = if (keystore != null) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    testOptions { unitTests.isReturnDefaultValues = true }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    if (hasSdk) {
        implementation(files(sdkDir.resolve("discord_partner_sdk.aar")))
        implementation("androidx.browser:browser:1.8.0")   // the SDK's sign-in flow needs it
    }
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
