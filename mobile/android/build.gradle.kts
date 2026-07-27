allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Force every Android library plugin (file_picker, path_provider, etc.) to
// compile against API 36. The Flutter tool hands plugins a compileSdk of 34
// here, but file_picker's dependency chain now requires 36, and raising it on
// the app module alone does not reach the plugin subprojects. compileSdk only
// affects which APIs are visible at build time, so forcing the newest installed
// platform on the libraries is safe.
//
// This must be registered BEFORE the evaluationDependsOn block below, which
// eagerly evaluates the plugin subprojects — registering afterEvaluate on an
// already-evaluated project throws.
subprojects {
    afterEvaluate {
        val androidExtension = project.extensions.findByName("android")
        if (androidExtension is com.android.build.gradle.BaseExtension) {
            androidExtension.compileSdkVersion(36)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
