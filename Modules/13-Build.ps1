#Requires -Version 5.1
#=============================================================================
# 13-Build.ps1 - 环境初始化、缓存清理与构建主流程
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================

# =============================================================================
# 缓存清理
# =============================================================================

function Clear-BuildCaches {
    $gradlew = Join-Path $script:AndroidDir "gradlew.bat"
    if (Test-Path -LiteralPath $gradlew) {
        Write-BuildInfo "正在停止 Gradle Daemon..."
        # --stop 依据 GRADLE_USER_HOME 定位 daemon，必须先指向构建时使用的短路径 home，
        # 否则会停到默认 home 上，残留 daemon 继续持有缓存文件锁
        $prevGradleUserHome = $env:GRADLE_USER_HOME
        if (-not [string]::IsNullOrWhiteSpace($script:GradleUserHome)) {
            $env:GRADLE_USER_HOME = $script:GradleUserHome
        }
        Push-Location $script:AndroidDir
        try {
            & $gradlew --stop | Out-Host
        }
        catch {
            Write-BuildWarn "停止 Gradle Daemon 失败：$($_.Exception.Message)"
        }
        finally {
            Pop-Location
            $env:GRADLE_USER_HOME = $prevGradleUserHome
        }
        # 等待 Gradle 释放文件句柄，避免清理缓存时报占用错误
        Start-Sleep -Seconds 2
    }

    Write-BuildWarn "正在清理 Android / Expo / Metro / Gradle / Cordova 缓存..."

    $projectTargets = [System.Collections.Generic.List[string]]::new()
    # 仅删除 Android 构建产物，保留源码与配置
    $projectTargets.Add((Join-Path $script:AndroidDir "build"))
    $projectTargets.Add((Join-Path $script:AndroidDir "app\build"))
    $projectTargets.Add((Join-Path $script:AndroidDir ".gradle"))
    $projectTargets.Add((Join-Path $script:MobileRoot "build"))
    $projectTargets.Add((Join-Path $script:MobileRoot ".dart_tool"))
    $projectTargets.Add((Join-Path $script:MobileRoot ".expo"))
    $projectTargets.Add((Join-Path $script:ProjectRoot ".expo-home"))
    $projectTargets.Add((Join-Path $script:ProjectRoot "node_modules\.cache"))
    $projectTargets.Add((Join-Path $script:MobileRoot "node_modules\.cache"))

    # Cordova 专属缓存：platforms\android 下构建产物（platforms 目录本身由 cordova 管理，不删除）
    $cordovaAndroidDir = Join-Path $script:MobileRoot "platforms\android"
    if (Test-Path -LiteralPath $cordovaAndroidDir) {
        $projectTargets.Add((Join-Path $cordovaAndroidDir "build"))
        $projectTargets.Add((Join-Path $cordovaAndroidDir "app\build"))
        $projectTargets.Add((Join-Path $cordovaAndroidDir ".gradle"))
    }

    $modulesRoot = Join-Path $script:MobileRoot "modules"
    if (Test-Path -LiteralPath $modulesRoot) {
        Get-ChildItem -LiteralPath $modulesRoot -Directory | ForEach-Object {
            $projectTargets.Add((Join-Path $_.FullName "android\build"))
        }
    }

    # 清理各包的 CMake 构建目录（.cxx）：build.ninja 内部硬编码 GRADLE_USER_HOME 绝对路径，
    # 缓存迁移/路径变更后必须重建；Gradle 的 up-to-date 判定不会自动发现这类过期
    $nmDir = Join-Path $script:MobileRoot "node_modules"
    if (Test-Path -LiteralPath $nmDir) {
        Get-ChildItem -LiteralPath $nmDir -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -in @('.bin', '.cache')) { return }
            if ($_.Name.StartsWith('@')) {
                Get-ChildItem -LiteralPath $_.FullName -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    $projectTargets.Add((Join-Path $_.FullName "android\.cxx"))
                }
            }
            else {
                $projectTargets.Add((Join-Path $_.FullName "android\.cxx"))
            }
        }
    }
    $projectTargets.Add((Join-Path $script:AndroidDir "app\.cxx"))

    foreach ($target in $projectTargets | Select-Object -Unique) {
        # 统一使用 Remove-DirectoryRobust（robocopy 镜像空目录法兜底），
        # 根治 RN node_modules、.cxx 与 Cordova platforms\android 等深路径撞 260 上限
        if (Test-Path -LiteralPath $target) {
            $resolvedTarget = [System.IO.Path]::GetFullPath($target).TrimEnd('\')
            $rootPrefix = ([System.IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\')) + '\'
            if (-not $resolvedTarget.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to clear a path outside the allowed root: $resolvedTarget"
            }
            Write-BuildWarn "正在清理：$resolvedTarget"
            if (-not (Remove-DirectoryRobust -Path $resolvedTarget)) {
                Write-BuildWarn "清理失败（可能文件被占用）：$resolvedTarget"
            }
        }
    }

    # 清理全局缓存目录（按项目隔离）
    $globalTargets = [System.Collections.Generic.List[string]]::new()
    $globalTargets.Add((Join-Path $script:ProjectCacheDir "android-home"))
    # 新短路径 GRADLE_USER_HOME + 旧长路径（兼容清理历史缓存）
    if (-not [string]::IsNullOrWhiteSpace($script:GradleUserHome)) {
        $globalTargets.Add($script:GradleUserHome)
    }
    $globalTargets.Add((Join-Path $script:ProjectCacheDir "gradle-home-apk"))
    $globalTargets.Add((Join-Path $script:ProjectCacheDir "staging"))

    foreach ($target in $globalTargets | Select-Object -Unique) {
        # 新 GRADLE_USER_HOME 位于 GlobalCacheRoot 之外，统一以 GlobalToolsRoot 为允许根；
        # 用户若把 gradleUserHome 配到全局工具目录之外，则跳过并提示手动清理
        $resolvedTarget = [System.IO.Path]::GetFullPath($target).TrimEnd('\')
        $rootPrefix = ([System.IO.Path]::GetFullPath($script:GlobalToolsRoot).TrimEnd('\')) + '\'
        if ($resolvedTarget.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $target) {
                Write-BuildWarn "正在清理：$resolvedTarget"
                if (-not (Remove-DirectoryRobust -Path $resolvedTarget)) {
                    Write-BuildWarn "清理失败（可能文件被占用）：$resolvedTarget"
                }
            }
        }
        else {
            Write-BuildWarn "跳过清理（位于全局工具目录之外，请手动删除）：$resolvedTarget"
        }
    }

    Write-BuildInfo "缓存清理完成。签名文件与已生成的 release APK 已保留。"
}


# =============================================================================
# 环境配置（仅安装依赖，不执行构建）
# =============================================================================

function Initialize-BuildEnvironment {
    Write-BuildInfo "开始配置构建环境..."
    # Cordova 项目：按 cordova-android 版本自适应 JDK 主版本（必须先于 Install-PortableJdk）
    if ($script:IsCordovaProject) {
        Resolve-CordovaJdkMajorVersion
    }
    $jdkHome = Install-PortableJdk
    # Flutter / 纯原生 Android 项目无需 Node.js
    if ($script:IsFlutterProject) {
        Write-BuildInfo "Flutter 项目，跳过 Node.js 安装。"
    }
    elseif (Test-Path -LiteralPath (Join-Path $script:MobileRoot 'package.json')) {
        Install-PortableNode
    }
    else {
        Write-BuildInfo "未检测到 package.json，跳过 Node.js 安装（纯原生 Android 项目）。"
    }
    $sdkRoot = Install-PortableAndroidSdk

    # Flutter 项目：与构建流程对齐，确保 Flutter SDK 可用（内部会先确保便携 git 可用）
    $flutterHome = $null
    if ($script:IsFlutterProject) {
        $flutterHome = Install-PortableFlutterSdk
        $env:FLUTTER_ROOT = $flutterHome
    }

    # Cordova 项目：确保 CLI 可用（会话级注入 npm 镜像，不污染用户全局配置）
    if ($script:IsCordovaProject) {
        if (-not [string]::IsNullOrWhiteSpace($script:CordovaNpmRegistry)) {
            $env:NPM_CONFIG_REGISTRY = $script:CordovaNpmRegistry
        }
        Install-CordovaCli
    }

    Write-BuildInfo "环境配置完成："
    Write-BuildInfo "  JAVA_HOME = $jdkHome"
    Write-BuildInfo "  ANDROID_SDK_ROOT = $sdkRoot"
    if ($flutterHome) {
        Write-BuildInfo "  FLUTTER_ROOT = $flutterHome"
    }
    Write-BuildInfo "  PATH 已注入当前会话（未修改系统变量）"
}

function Start-ReleaseBuild {
    # 保存原始环境变量，finally 中恢复
    $originalEnv = @{
        JAVA_HOME                 = $env:JAVA_HOME
        ANDROID_HOME              = $env:ANDROID_HOME
        ANDROID_SDK_ROOT          = $env:ANDROID_SDK_ROOT
        ANDROID_USER_HOME         = $env:ANDROID_USER_HOME
        GRADLE_USER_HOME          = $env:GRADLE_USER_HOME
        NODE_ENV                  = $env:NODE_ENV
        PATH                      = $env:PATH
        PUB_HOSTED_URL            = $env:PUB_HOSTED_URL
        FLUTTER_STORAGE_BASE_URL  = $env:FLUTTER_STORAGE_BASE_URL
        FLUTTER_ROOT              = $env:FLUTTER_ROOT
        NPM_CONFIG_REGISTRY       = $env:NPM_CONFIG_REGISTRY
        CORDOVA_ANDROID_GRADLE_DISTRIBUTION_URL = $env:CORDOVA_ANDROID_GRADLE_DISTRIBUTION_URL
    }

    # GIT_CONFIG_* 由 Set-GitCloneMirror 注入且条数不定（逐仓库修正无上限），
    # 枚举进程内现存的全部 GIT_CONFIG_COUNT / KEY_n / VALUE_n 完整备份，finally 中先清后还原
    $originalGitConfig = @{}
    foreach ($entry in [System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Process).GetEnumerator()) {
        if ($entry.Key -match '^GIT_CONFIG_(COUNT|KEY_\d+|VALUE_\d+)$') {
            $originalGitConfig[$entry.Key] = $entry.Value
        }
    }

    try {
        # 0. Cordova 项目：按 cordova-android 版本自适应 JDK 主版本（必须先于 Install-PortableJdk）
        if ($script:IsCordovaProject) {
            Resolve-CordovaJdkMajorVersion
        }
        # 其他项目类型：按 RN 版本或 AGP 版本自适应 JDK（Cordova 内部跳过）
        Resolve-ProjectJdkMajorVersion

        # 1. 准备依赖
        $javaHome = Install-PortableJdk
        # 纯原生 Android / Flutter 项目无需 Node.js（无 package.json 时跳过下载与检测）
        if (-not $script:IsFlutterProject -and (Test-Path -LiteralPath (Join-Path $script:MobileRoot 'package.json'))) {
            Install-PortableNode
        }
        elseif ($script:IsFlutterProject) {
            Write-BuildInfo "Flutter 项目，跳过 Node.js 安装。"
        }
        else {
            Write-BuildInfo "未检测到 package.json，跳过 Node.js 安装（纯原生 Android 项目）。"
        }
        $sdkRoot = Install-PortableAndroidSdk

        # Flutter 项目：注入 pub/引擎国内镜像，并确保 Flutter SDK 可用
        $flutterHome = $null
        if ($script:IsFlutterProject) {
            $env:PUB_HOSTED_URL = $script:PubHostedUrl
            $env:FLUTTER_STORAGE_BASE_URL = $script:FlutterStorageBaseUrl
            $flutterHome = Install-PortableFlutterSdk
            $env:FLUTTER_ROOT = $flutterHome
            # pubspec 中的 git 依赖走 GitHub 镜像（会话级 insteadOf 重写）
            Set-GitCloneMirror
            Write-BuildInfo "使用 Flutter SDK：$flutterHome"
        }

        # 2. 设置当前进程环境变量（不污染系统）
        $env:JAVA_HOME = $javaHome
        $env:ANDROID_HOME = $sdkRoot
        $env:ANDROID_SDK_ROOT = $sdkRoot
        $env:ANDROID_USER_HOME = Join-Path $script:ProjectCacheDir "android-home"
        # 使用短路径 GRADLE_USER_HOME：避免 transforms/prefab 深层路径突破 Win32 260 字符上限
        $env:GRADLE_USER_HOME = $script:GradleUserHome
        # Cordova 项目必须排除 production：平台/插件常声明在 devDependencies（platform add --save
        # 的默认落点），NODE_ENV=production 会让 npm 进入 --omit=dev 模式，把 cordova-fetch 内部的
        # npm install <pkg> --no-save 变成静默空操作（退出码 0 但未安装），随后误报
        # Cannot find module 'cordova-android/package.json'。显式 development 同时覆盖外部环境传入的 production。
        if ($script:IsCordovaProject) {
            $env:NODE_ENV = 'development'
        }
        else {
            $env:NODE_ENV = "production"
        }

        # Cordova 项目：会话级注入 npm registry 镜像（优先级高于 .npmrc，不改用户全局配置；
        # 覆盖 npm install -g cordova 与 cordova platform add 内部 npm 调用；finally 中由 originalEnv 恢复）
        if ($script:IsCordovaProject -and -not [string]::IsNullOrWhiteSpace($script:CordovaNpmRegistry)) {
            $env:NPM_CONFIG_REGISTRY = $script:CordovaNpmRegistry
            Write-BuildInfo "npm registry 镜像（会话级注入）：$env:NPM_CONFIG_REGISTRY"
        }

        New-Item -ItemType Directory -Path $env:ANDROID_USER_HOME,$env:GRADLE_USER_HOME -Force | Out-Null

        # 2.1 写入项目级 Gradle 全局配置：
        #   console=plain             —— 禁用富控制台状态栏，避免非 ANSI 终端刷出大量 IDLE 行
        #   auto-download=false       —— 禁止 foojay-resolver 从 api.foojay.io 自动下载 JDK
        #   auto-detect=false + paths —— toolchain 仅使用脚本提供的 JDK，保证可复现
        #   jvmargs=-Xmx4g ...        —— 强制 4G 堆，防止编译/合并资源时频繁 GC（兜底，
        #                               项目级 android/gradle.properties 由 Set-GradleMemory 强制覆盖）
        $gradlePropertiesPath = Join-Path $env:GRADLE_USER_HOME "gradle.properties"
        $gradleProperties = @(
            'org.gradle.console=plain'
            'org.gradle.java.installations.auto-download=false'
            'org.gradle.java.installations.auto-detect=false'
            "org.gradle.java.installations.paths=$(Convert-ToGradlePath $javaHome)"
            'org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=512m -XX:+HeapDumpOnOutOfMemoryError -Dfile.encoding=UTF-8'
        )
        Set-Content -LiteralPath $gradlePropertiesPath -Value $gradleProperties -Encoding ASCII -Force

        Write-BuildInfo "使用 JDK：$javaHome"
        Write-BuildInfo "使用 Android SDK：$sdkRoot"
        Write-BuildInfo "使用 Gradle 缓存：$env:GRADLE_USER_HOME"

        # 2.2 内存预检：总内存/可用内存不足时给出醒目提示，再由用户决定是否继续
        Test-BuildMemory
        # 2.2b 磁盘预检：工具盘/项目盘剩余 <8GB 时醒目提示（NDK/SDK 下载与缓存都是空间大户）
        Test-BuildDiskSpace

        # 2.3 长路径预检：未启用 LongPathsEnabled 时提示（双保险，主要防线是短路径 GRADLE_USER_HOME）
        Test-WindowsLongPathSupport

        # 确认是否开始编译，默认 Y
        $confirm = Read-Host "依赖已准备就绪，是否开始编译（Y/n，默认为 Y）"
        if ($confirm -and ($confirm -notmatch '^(Y|y)$')) {
            Write-BuildInfo "已取消编译。"
            return
        }

        # 构建日志落盘：pub get / flutter build / gradlew 的输出同步写入日志文件，
        # 便于构建失败后排查与反馈（UTF-8 无 BOM；AutoFlush 防止异常中断丢失尾部日志）
        $logDir = Join-Path $script:ProjectCacheDir 'logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $script:BuildLogPath = Join-Path $logDir ("build-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        $script:BuildLogWriter = [System.IO.StreamWriter]::new($script:BuildLogPath, $true, [System.Text.UTF8Encoding]::new($false))
        $script:BuildLogWriter.AutoFlush = $true
        Write-BuildInfo "构建日志文件：$script:BuildLogPath"

        # 确保 Node 依赖就绪（已有 android 目录的路径也需要 node_modules 才能编译）
        Ensure-NodeModules

        # Cordova 项目：使用 Cordova 专用构建流程（内部处理调试/正式双版本、签名与输出）
        if ($script:IsCordovaProject) {
            Write-BuildInfo "Cordova 项目，使用 Cordova 构建流程。"
            Build-CordovaAllApks
            return
        }

        # 3. 处理 Android 项目（兼容 Flutter / Expo / RN CLI / 原生 Android）
        if ($script:IsFlutterProject) {
            if (Test-Path -LiteralPath $script:AndroidDir) {
                Write-BuildInfo "Flutter 项目：检测到现有 android 目录。"
            }
            else {
                # Flutter 特征校验要求 android 目录，此处为 Auto 检测兜底：pubspec 存在但 android 缺失时补全
                Write-BuildWarn "Flutter 项目缺少 android 目录，正在通过 flutter create 生成..."
                Push-Location $script:MobileRoot
                try {
                    & (Join-Path $flutterHome 'bin\flutter.bat') create --platforms android .
                    if ($LASTEXITCODE -ne 0) {
                        throw "flutter create 生成 android 目录失败，退出码 $LASTEXITCODE。"
                    }
                }
                finally {
                    Pop-Location
                }
            }
        }
        elseif ($script:IsNativeAndroidProject) {
            Write-BuildInfo "原生 Android 项目，跳过 prebuild，直接使用 Gradle 构建。"
        }
        elseif (Test-Path -LiteralPath $script:AndroidDir) {
            Write-BuildInfo "检测到现有 android 目录，跳过 prebuild，直接使用 Gradle 构建。"
        }
        else {
            if (Test-ExpoProject) {
                Write-BuildInfo "未检测到 android 目录，且项目包含 Expo 依赖，正在执行 prebuild..."
                Push-Location $script:MobileRoot
                try {
                    & npx expo prebuild --platform android --clean --no-install
                    if ($LASTEXITCODE -ne 0) {
                        throw "Expo prebuild 失败，退出码 $LASTEXITCODE。"
                    }
                }
                finally {
                    Pop-Location
                }
            }
            else {
                throw "当前项目不是 Expo 项目，且没有 android 文件夹，无法继续构建。"
            }
        }

        # 基本检查：优先 app 模块（RN/Expo 及单模块原生项目）；
        # 多模块原生项目模块名可能不同，扫描一层模块目录兜底，仍找不到则交由 Gradle 自行校验
        $generatedManifest = Join-Path $script:AndroidDir "app\src\main\AndroidManifest.xml"
        if (-not (Test-Path -LiteralPath $generatedManifest)) {
            $generatedManifest = Get-ChildItem -LiteralPath $script:AndroidDir -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'src\main\AndroidManifest.xml' } |
                Where-Object { Test-Path -LiteralPath $_ } |
                Select-Object -First 1
        }
        if (-not $generatedManifest) {
            if ($script:IsNativeAndroidProject) {
                Write-BuildWarn "未能在常见模块中找到 AndroidManifest.xml，将由 Gradle 构建自行校验。"
            }
            else {
                throw "未找到生成的 AndroidManifest.xml：$(Join-Path $script:AndroidDir 'app\src\main\AndroidManifest.xml')"
            }
        }
        else {
            Write-BuildInfo "Android 项目已生成并通过基本检查。"
        }

        $gradlew = Join-Path $script:AndroidDir "gradlew.bat"

        # Flutter 项目允许 gradlew 缺失（flutter build 会自动注入 wrapper）。
        # 提前从 Flutter SDK 自带模板补齐缺失的 wrapper 文件（不覆盖项目已有文件），
        # 使后续 Set-GradleWrapperMirror 换源生效——否则 flutter 自动注入时
        # Gradle 发行版将走 services.gradle.org 官方源下载，国内速度慢。
        if ($script:IsFlutterProject -and -not (Test-Path -LiteralPath $gradlew)) {
            $wrapperTemplateDir = Join-Path $flutterHome 'bin\cache\artifacts\gradle_wrapper'
            if (Test-Path -LiteralPath (Join-Path $wrapperTemplateDir 'gradlew.bat')) {
                Write-BuildInfo 'android 目录缺少 gradlew，正在从 Flutter SDK 模板补齐 Gradle wrapper...'
                foreach ($item in (Get-ChildItem -LiteralPath $wrapperTemplateDir -Recurse -File -ErrorAction SilentlyContinue)) {
                    $relative = $item.FullName.Substring($wrapperTemplateDir.Length).TrimStart('\')
                    $dest = Join-Path $script:AndroidDir $relative
                    if (-not (Test-Path -LiteralPath $dest)) {
                        $destDir = Split-Path -Parent $dest
                        if (-not (Test-Path -LiteralPath $destDir)) {
                            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                        }
                        Copy-Item -LiteralPath $item.FullName -Destination $dest -Force
                    }
                }
            }
            else {
                Write-BuildWarn 'Flutter SDK 内未找到 Gradle wrapper 模板，将由 flutter build 自动注入（Gradle 发行版可能走官方源下载）。'
            }
        }
        elseif (-not (Test-Path -LiteralPath $gradlew)) {
            throw "未找到 gradlew.bat：$gradlew"
        }

        # 4. 写入 local.properties
        $localProperties = Join-Path $script:AndroidDir "local.properties"
        Set-Content -LiteralPath $localProperties `
            -Value "sdk.dir=$(Convert-ToGradlePath $sdkRoot)" `
            -Encoding ASCII -Force -ErrorAction Stop

        # Flutter 项目：显式写入 flutter.sdk（flutter 工具运行时也会自动维护，此处提前落盘保险）
        if ($script:IsFlutterProject) {
            Add-Content -LiteralPath $localProperties `
                -Value "flutter.sdk=$(Convert-ToGradlePath $flutterHome)" `
                -Encoding ASCII -ErrorAction Stop
        }

        # 按项目声明检测并补装缺失的 SDK Platform / build-tools / NDK（NDK 默认询问后安装）
        Install-ProjectSdkRequirements

        # 替换 gradle-wrapper.properties 为国内镜像，避免 Gradle Wrapper 下载超时
        Set-GradleWrapperMirror

        # 强制 Gradle 守护进程 4G 堆内存（覆盖 Expo/RN 模板默认的 -Xmx2048m）
        Set-GradleMemory

        # 将 Maven Central / Google / Gradle Plugin Portal 统一换源为阿里云镜像（含连通性探测）
        Set-GradleMirror

        # 预检 transforms 缓存：清除上次构建被强制中断留下的残缺条目
        Repair-GradleTransformCache

        # 预检 CMake 缓存：GRADLE_USER_HOME 变更后 .cxx 内旧 build.ninja 仍引用旧路径，需清理重建
        Remove-StaleCxxBuildDirs -CurrentGradleUserHome $env:GRADLE_USER_HOME

        # 5. 构建（Flutter 走 flutter build apk，其余走 Gradle；Gradle 含 transforms 损坏自动清理与重试）
        if ($script:IsFlutterProject) {
            Invoke-FlutterBuildApk -FlutterHome $flutterHome
        }
        else {
            Invoke-GradleAssembleRelease -Gradlew $gradlew
        }

        # 6. 定位待签名 APK
        if ($script:IsFlutterProject) {
            # Flutter 专属输出路径；模板 release 默认带 debug 签名，后续 apksigner sign 用新 keystore 整体替换
            $flutterApkPath = Join-Path $script:MobileRoot "build\app\outputs\flutter-apk\app-release.apk"
            $unsignedApk = Get-Item -LiteralPath $flutterApkPath -ErrorAction SilentlyContinue
            if (-not $unsignedApk) {
                throw "Flutter 构建完成，但未找到 release APK：$flutterApkPath"
            }
        }
        else {
            # 优先 app-release-unsigned.apk，回退到最新 APK
            $apkDir = Join-Path $script:AndroidDir "app\build\outputs\apk\release"
            $unsignedApk = Get-ChildItem -LiteralPath $apkDir -Filter "app-release-unsigned.apk" -File -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if (-not $unsignedApk) {
                Write-BuildWarn "未找到 app-release-unsigned.apk，将回退到按修改时间选择最新 APK。"
                $unsignedApk = Get-ChildItem -LiteralPath $apkDir -Filter "*.apk" -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1
            }

            if (-not $unsignedApk) {
                # 多模块原生项目：应用模块名可能不是 app，扫描所有模块的 release 输出目录
                $unsignedApk = Get-ChildItem -LiteralPath $script:AndroidDir -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { Join-Path $_.FullName "build\outputs\apk\release" } |
                    Where-Object { Test-Path -LiteralPath $_ } |
                    ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter "*.apk" -File -ErrorAction SilentlyContinue } |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1
            }

            if (-not $unsignedApk) {
                throw "Gradle 构建完成，但未找到 release APK。"
            }
        }
        Write-BuildInfo "找到待签名 APK：$($unsignedApk.FullName)"

        # 7. 签名并输出到 release 目录（zipalign → apksigner → 校验 → 复制，全流程封装在 12-Signing）
        $finalApk = Invoke-ApkSignAndPublish -UnsignedApkPath $unsignedApk.FullName -JavaHome $javaHome -SdkRoot $sdkRoot
    }
    finally {
        # 先停止 Gradle Daemon（必须在恢复环境变量之前：
        # --stop 依据 GRADLE_USER_HOME 定位 daemon，恢复后会停到错误的 home 上）
        $gradlew = Join-Path $script:AndroidDir "gradlew.bat"
        if (Test-Path -LiteralPath $gradlew) {
            Write-BuildInfo "正在停止 Gradle Daemon..."
            Push-Location $script:AndroidDir
            try {
                & $gradlew --stop | Out-Null
            }
            catch {
                Write-BuildWarn "Gradle --stop 执行失败（可能被忽略）：$($_.Exception.Message)"
            }
            finally {
                Pop-Location
            }
        }

        # 恢复环境变量
        foreach ($key in $originalEnv.Keys) {
            [System.Environment]::SetEnvironmentVariable($key, $originalEnv[$key], [System.EnvironmentVariableTarget]::Process)
        }

        # 恢复 GIT_CONFIG_*：先清除当前全部条目（Set-GitCloneMirror 注入条数不定），再还原备份值
        $currentGitConfigKeys = @([System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Process).Keys |
            Where-Object { $_ -match '^GIT_CONFIG_(COUNT|KEY_\d+|VALUE_\d+)$' })
        foreach ($key in $currentGitConfigKeys) {
            [System.Environment]::SetEnvironmentVariable($key, $null, [System.EnvironmentVariableTarget]::Process)
        }
        foreach ($key in $originalGitConfig.Keys) {
            [System.Environment]::SetEnvironmentVariable($key, $originalGitConfig[$key], [System.EnvironmentVariableTarget]::Process)
        }

        # 关闭构建日志写入器
        if ($null -ne $script:BuildLogWriter) {
            try { $script:BuildLogWriter.Dispose() } catch { }
            $script:BuildLogWriter = $null
        }
    }
}
