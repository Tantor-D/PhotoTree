import java.util.Locale
import javax.xml.parsers.DocumentBuilderFactory
import java.security.KeyStore
import java.security.MessageDigest

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Maintainer builds require the pinned certificate for update compatibility.
val contributorDebug = providers.environmentVariable("PHOTOTREE_CONTRIBUTOR_DEBUG")
    .map { it.toBooleanStrict() }.getOrElse(false)
val developmentKeystore = rootProject.file(
    providers.environmentVariable("PHOTOTREE_SIGNING_STORE_FILE")
        .getOrElse("../.local-build-cache/android/debug.keystore")
)
val developmentCertificateSha256 =
    "0ef3bd40cad3c9b015b57974ea297a1931ed6590337459fdf4268c8cd017c4b8"

android {
    namespace = "io.github.tantor_d.phototree"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Local development identity; this application is not a store release.
        applicationId = "io.github.tantor_d.phototree"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 30
        externalNativeBuild {
            cmake { arguments += "-DANDROID_STL=c++_static" }
        }
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (!contributorDebug) {
        signingConfigs.getByName("debug").storeFile = developmentKeystore
    }

    buildTypes {
        debug {
            if (contributorDebug) applicationIdSuffix = ".contributor"
        }
        release {
            // Non-debug acceptance build only; not signed for store distribution.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// Android can otherwise select a secondary Chinese locale ahead of the default label.
abstract class GenerateLauncherLabels : DefaultTask() {
    @get:InputFile
    abstract val phoneLocales: RegularFileProperty

    @get:InputFile
    abstract val englishLabel: RegularFileProperty

    @get:OutputDirectory
    abstract val resources: DirectoryProperty

    @TaskAction
    fun generate() {
        val root = resources.get().asFile
        root.deleteRecursively()
        val config = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(phoneLocales.get().asFile)
        val locales = config.getElementsByTagName("string-array")
        val supported = (0 until locales.length).map { locales.item(it) }
            .single { it.attributes.getNamedItem("name").nodeValue == "supported_locales" }
        val entries = (supported as org.w3c.dom.Element).getElementsByTagName("item")
        val qualifiers = (0 until entries.length)
            .map { Locale.forLanguageTag(entries.item(it).textContent.trim()) }
            .filter { it.language.isNotEmpty() && it.language != "zh" }
            .map { listOf(it.language, it.script).filter(String::isNotEmpty).joinToString("+") }
            .toSet()
        for (qualifier in qualifiers) {
            val target = root.resolve("values-b+$qualifier/strings.xml")
            target.parentFile.mkdirs()
            englishLabel.get().asFile.copyTo(target)
        }
    }
}

androidComponents.beforeVariants { variant ->
    if (contributorDebug && variant.buildType != "debug") variant.enable = false
}

val sdkLocaleList = androidComponents.sdkComponents.sdkDirectory.map {
    it.file("platforms/android-${android.compileSdk}/data/res/values/locale_config.xml")
}
androidComponents.onVariants { variant ->
    val launcherLabels = tasks.register<GenerateLauncherLabels>(
        "generate${variant.name.replaceFirstChar(Char::uppercaseChar)}LauncherLabels"
    ) {
        phoneLocales.set(sdkLocaleList)
        englishLabel.set(layout.projectDirectory.file("src/main/res/values/strings.xml"))
    }
    variant.sources.res?.addGeneratedSourceDirectory(launcherLabels, GenerateLauncherLabels::resources)
}

if (!contributorDebug) {
    val developmentSigning = android.signingConfigs.getByName("debug")
    val developmentStorePassword = developmentSigning.storePassword
    val developmentKeyAlias = developmentSigning.keyAlias
    val verifyPhotoTreeSigning = tasks.register("verifyPhotoTreeSigning") {
        doLast {
            check(developmentKeystore.isFile) {
                "PhotoTree maintainer signing keystore is missing. Set PHOTOTREE_SIGNING_STORE_FILE " +
                    "to the existing maintainer keystore; do not generate a replacement."
            }
            val store = KeyStore.getInstance(developmentKeystore, developmentStorePassword!!.toCharArray())
            val certificate = checkNotNull(store.getCertificate(developmentKeyAlias)) {
                "PhotoTree maintainer signing certificate is missing."
            }
            val fingerprint = MessageDigest.getInstance("SHA-256")
                .digest(certificate.encoded).joinToString("") { "%02x".format(it) }
            check(fingerprint == developmentCertificateSha256) {
                "PhotoTree signing certificate does not match the maintainer identity. Build stopped to preserve upgrade compatibility."
            }
        }
    }
    tasks.named("preBuild") { dependsOn(verifyPhotoTreeSigning) }
    tasks.matching { it.name.startsWith("validateSigning") }.configureEach {
        dependsOn(verifyPhotoTreeSigning)
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
