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

// 统一所有 Android 子模块的 NDK 版本到本机已安装的版本。
//
// Flutter 3.41.8 默认要求 28.2.13676358，但本机该目录是空的，而 dl.google.com
// 在当前网络下只有约 80KB/s（整包需数小时）；本机已有完整的 29.0.14206865。
// 传递依赖 jni 的 android 模块同样使用 flutter.ndkVersion，只在 app 模块覆盖
// 不够（会报 CXX1101 缺少 source.properties），必须在根项目统一设置。
//
// 这段必须排在下面的 evaluationDependsOn(":app") 之前：那行会立即触发 :app
// 求值，之后再注册 afterEvaluate 会抛 "project is already evaluated"。
subprojects {
    afterEvaluate {
        val androidExtension = extensions.findByName("android") ?: return@afterEvaluate
        runCatching {
            androidExtension.javaClass
                .getMethod("setNdkVersion", String::class.java)
                .invoke(androidExtension, "29.0.14206865")
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
