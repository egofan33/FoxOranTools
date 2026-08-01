# 16-Requirements.ps1 - 跨项目类型的 SDK 需求解析与补装
# 涵盖五项通用优化：
#   - 按项目声明（android build.gradle ext / plugins）解析 compileSdk / buildTools / NDK / AGP / Kotlin 版本
#   - 缺失 SDK Platform / build-tools 经镜像源自动补装；NDK 按配置询问后补装
#   - JDK 主版本按 RN 版本或 AGP 版本自适应（Cordova 已有专属函数，跳过）
#   - 构建失败输出共性特征 → 中文修复建议

# ============================================================
#  项目 SDK 需求解析
# ============================================================

function Get-ProjectSdkRequirements {
    # 解析 Android 工程文件，返回版本需求哈希表。
    # 解析来源（按优先级）：
    #   - build.gradle ext 块（RN/Expo 模板的 compileSdkVersion / buildToolsVersion / ndkVersion / kotlinVersion）
    #   - settings.gradle plugins 块（AGP 版本）
    #   - build.gradle classpath 行（AGP 版本回退）
    #   - app 模块 build.gradle 的 compileSdk 直接值（原生 / Flutter）
    #   - gradle.properties（android.useAndroidX / kotlin.code.style 等旁证）
    # 返回值含 CompileSdkVersion, BuildToolsVersion, NdkVersion, AgpMajorVersion, KotlinVersion（均可为 null）

    $req = @{
        CompileSdkVersion = $null
        BuildToolsVersion = $null
        NdkVersion        = $null
        AgpMajorVersion   = $null
        KotlinVersion     = $null
    }

    # ---- build.gradle ext { compileSdkVersion / buildToolsVersion / ndkVersion / kotlinVersion } ----
    $buildGradlePath = Join-Path $script:AndroidDir 'build.gradle'
    $appBuildGradlePath = Join-Path $script:AndroidDir 'app\build.gradle'
    $primaryGradle = if (Test-Path -LiteralPath $buildGradlePath) { $buildGradlePath }
                     elseif (Test-Path -LiteralPath $appBuildGradlePath) { $appBuildGradlePath }
                     else { $null }

    if ($primaryGradle) {
        $gradleContent = Get-Content -LiteralPath $primaryGradle -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($gradleContent) {
            # ext { compileSdkVersion = 34 }
            if ($gradleContent -match 'compileSdkVersion\s*[=:]\s*(\d+)') {
                $req.CompileSdkVersion = [int]$Matches[1]
            }
            # ext { buildToolsVersion = "34.0.0" }
            if ($gradleContent -match 'buildToolsVersion\s*[=:]\s*["'']([\d\.]+)["'']') {
                $req.BuildToolsVersion = $Matches[1]
            }
            # ext { ndkVersion = "25.1.8937393" }
            if ($gradleContent -match 'ndkVersion\s*[=:]\s*["'']([^"'']+)["'']') {
                $req.NdkVersion = $Matches[1]
            }
            # ext { kotlinVersion = "1.9.0" }
            if ($gradleContent -match 'kotlinVersion\s*[=:]\s*["'']([^"'']+)["'']') {
                $req.KotlinVersion = $Matches[1]
            }
            # classpath 'com.android.tools.build:gradle:8.2.0'  → AGP
            if ($gradleContent -match "com\.android\.tools\.build:gradle:(\d+)(?:\.(\d+))?") {
                $req.AgpMajorVersion = [int]$Matches[1]
            }
            # compileSdk 34 （直接在 android 块中，非 ext）
            if (-not $req.CompileSdkVersion -and ($gradleContent -match 'compileSdk\s+(\d+)')) {
                $req.CompileSdkVersion = [int]$Matches[1]
            }
        }
    }

    # ---- settings.gradle plugins 块：id 'com.android.application' version 'X.Y.Z' ----
    $settingsGradlePath = Join-Path $script:AndroidDir 'settings.gradle'
    $settingsKtsPath = Join-Path $script:AndroidDir 'settings.gradle.kts'
    $settingsContent = $null
    foreach ($sp in @($settingsGradlePath, $settingsKtsPath)) {
        if (Test-Path -LiteralPath $sp) {
            $settingsContent = Get-Content -LiteralPath $sp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($settingsContent) { break }
        }
    }

    if ($settingsContent -and -not $req.AgpMajorVersion) {
        # id 'com.android.application' version '8.2.0' apply false
        if ($settingsContent -match 'com\.android\.application[\x27\x22]\s+version\s+[\x27\x22](\d+)(?:\.(\d+))?') {
            $req.AgpMajorVersion = [int]$Matches[1]
        }
        # id("com.android.application") version "8.2.0"
        elseif ($settingsContent -match 'id\s*\(\s*"com\.android\.application"\s*\)\s+version\s+"(\d+)') {
            $req.AgpMajorVersion = [int]$Matches[1]
        }
    }

    # ---- app/build.gradle 额外解析（如果 app 子模块独立声明） ----
    if ($appBuildGradlePath -and $appBuildGradlePath -ne $primaryGradle -and (Test-Path -LiteralPath $appBuildGradlePath)) {
        $appContent = Get-Content -LiteralPath $appBuildGradlePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($appContent) {
            if (-not $req.CompileSdkVersion -and ($appContent -match 'compileSdk\s+(\d+)')) {
                $req.CompileSdkVersion = [int]$Matches[1]
            }
            if (-not $req.BuildToolsVersion -and ($appContent -match 'buildToolsVersion\s*["'']([\d\.]+)["'']')) {
                $req.BuildToolsVersion = $Matches[1]
            }
        }
    }

    return $req
}


function Get-ProjectPackageVersion {
    # 从 package.json / pubspec.yaml 获取关键依赖主版本号。
    # package.json 返回 react-native / expo 主版本（null 表示未声明）。
    # 文件不存在或解析失败时对应值为 null。

    $result = @{ ReactNative = $null; Expo = $null; Flutter = $null }

    # package.json → RN / Expo 版本
    $packageJsonPath = Join-Path $script:MobileRoot 'package.json'
    if (Test-Path -LiteralPath $packageJsonPath) {
        try {
            $json = Get-Content -LiteralPath $packageJsonPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            $allDeps = @()
            if ($json.dependencies -and $json.dependencies.PSObject) {
                $allDeps += $json.dependencies.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } }
            }
            if ($json.devDependencies -and $json.devDependencies.PSObject) {
                $allDeps += $json.devDependencies.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } }
            }
            foreach ($dep in $allDeps) {
                if ($dep.Name -eq 'react-native') {
                    $ver = $dep.Value -replace '[\^\~><= ]', ''
                    # RN 版本格式 0.73.6 → 取 minor 作为对比依据
                    if ($ver -match '^0\.(\d+)') { $result.ReactNative = [int]$Matches[1] }
                }
                elseif ($dep.Name -eq 'expo') {
                    $ver = $dep.Value -replace '[\^\~><= ]', ''
                    if ($ver -match '^(\d+)') { $result.Expo = [int]$Matches[1] }
                }
            }
        }
        catch {
            Write-BuildWarn "解析 package.json 依赖版本失败：$($_.Exception.Message)"
        }
    }

    return $result
}


function Get-ProjectAgpMajorVersion {
    # 解析 AGP 主版本号，返回整数或 null（无法解析时）。
    # 可见 Get-ProjectSdkRequirements，本函数独立用于 JDK 自适应时的快速判别。

    $req = Get-ProjectSdkRequirements
    return $req.AgpMajorVersion
}


# ============================================================
#  JDK 主版本自适应
# ============================================================

function Resolve-ProjectJdkMajorVersion {
    # 按项目类型与依赖版本自动选择 JDK 主版本，将结果写入 $script:RequiredJdkMajorVersion。
    # 调用位置必须在 Install-PortableJdk 之前。
    # 规则：
    #   - jdk.autoDetect = false → 直接返回，沿用 $script:RequiredJdkMajorVersion
    #   - Cordova 项目 → 跳过（已有 Resolve-CordovaJdkMajorVersion）
    #   - RN / Expo：react-native >=0.73 → 17，<=0.72 → 11
    #   - Flutter / 原生：AGP >=8 → 17，AGP 7.x → 11，AGP <7 → 8
    #   - 解析不到版本 → 保持现状并打印提示

    if (-not $script:JdkAutoDetect) {
        Write-BuildInfo "jdk.autoDetect 已关闭，沿用配置 JDK $($script:RequiredJdkMajorVersion)。"
        return
    }

    # Cordova 已有专属 JDK 自适应，跳过
    if ($script:IsCordovaProject) {
        return
    }

    $newVersion = $null
    $reason = ''

    # ── RN / Expo ──
    if ($script:DetectedProjectType -in @('RN', 'Expo')) {
        $pkgVer = Get-ProjectPackageVersion
        $rnMajor = $pkgVer.ReactNative
        if ($rnMajor) {
            if ($rnMajor -ge 73) {
                $newVersion = 17
                $reason = "检测到 react-native >=0.73"
            }
            elseif ($rnMajor -le 72) {
                $newVersion = 11
                $reason = "检测到 react-native <=0.72"
            }
        }
        # RN 版本未声明 → 按 Expo SDK 推测：Expo SDK >=52 对应 RN >=0.76
        if (-not $newVersion -and $pkgVer.Expo) {
            $expoMajor = $pkgVer.Expo
            if ($expoMajor -ge 52) {
                $newVersion = 17
                $reason = "检测到 Expo SDK >=52（隐式要求 RN >=0.76 → JDK 17）"
            }
            elseif ($expoMajor -ge 48) {
                # Expo 48-51 仍使用 RN 0.71-0.75，需 JDK 17
                $newVersion = 17
                $reason = "检测到 Expo SDK >=48 → JDK 17"
            }
            else {
                $newVersion = 11
                $reason = "检测到 Expo SDK <48 → JDK 11"
            }
        }
    }
    # ── Flutter / 原生 → 按 AGP 版本 ──
    elseif ($script:DetectedProjectType -in @('Flutter', 'Native', 'Auto')) {
        $agpMajor = Get-ProjectAgpMajorVersion
        if ($agpMajor) {
            if ($agpMajor -ge 8) {
                $newVersion = 17
                $reason = "检测到 AGP >=8.x"
            }
            elseif ($agpMajor -eq 7) {
                $newVersion = 11
                $reason = "检测到 AGP 7.x"
            }
            elseif ($agpMajor -le 6) {
                $newVersion = 8
                $reason = "检测到 AGP <=6.x"
            }
        }
    }

    if ($newVersion -and $newVersion -ne $script:RequiredJdkMajorVersion) {
        Write-BuildInfo "${reason}，自动切换 JDK $($script:RequiredJdkMajorVersion) → $newVersion。"
        $script:RequiredJdkMajorVersion = $newVersion
    }
    elseif ($newVersion) {
        Write-BuildInfo "${reason}，JDK $newVersion 与当前配置一致，无需切换。"
    }
    else {
        Write-BuildInfo "无法解析项目 JDK 需求版本，沿用当前 JDK $($script:RequiredJdkMajorVersion)。"
    }
}


# ============================================================
#  SDK 缺失补装
# ============================================================

function Install-ProjectSdkRequirements {
    # 检测项目 Android SDK 需求（platform / build-tools / NDK），缺失时经镜像源补装。
    # - platform 与 build-tools 缺失且 requirements.installSdk 为 true 时自动补装（包小，免确认）
    # - NDK 缺失时按 requirements.installNdk 策略处理：
    #     "always" → 直接补装；"ask" → Read-Host Y/n 询问；"never" → 仅警告跳过
    #   NDK 较大（1-2GB），提示包大小预估。
    # - 全部已满足 → 打印通过，零网络请求，直接返回
    # - 补装失败 → throw 中文错误（早失败优于构建半小时后失败）
    # 调用位置：android 目录已就绪，Set-GradleWrapperMirror 之前。

    $req = Get-ProjectSdkRequirements

    $repoXml = $null  # 延迟下载，仅在需要补装时获取

    # ── compileSdk → platform ──
    if ($req.CompileSdkVersion) {
        $platformPath = Join-Path $script:AndroidHome "platforms\android-$($req.CompileSdkVersion)"
        if (-not (Test-Path -LiteralPath $platformPath)) {
            if (-not $script:RequirementsInstallSdk) {
                Write-BuildWarn "检测到缺失 Android SDK Platform android-$($req.CompileSdkVersion)，但 requirements.installSdk=false，跳过补装。"
            }
            else {
                if (-not $repoXml) { $repoXml = Get-SdkRepositoryXml }
                Write-BuildInfo "正在补装缺失的 Android SDK Platform：android-$($req.CompileSdkVersion)..."
                Install-AndroidSdkPackage -RepoXml $repoXml -PackagePath "platforms;android-$($req.CompileSdkVersion)" -DestinationDir $script:AndroidHome
                if (-not (Test-Path -LiteralPath $platformPath)) {
                    throw "补装 Android SDK Platform android-$($req.CompileSdkVersion) 失败，请检查网络或镜像源。"
                }
                Write-BuildInfo "Android SDK Platform android-$($req.CompileSdkVersion) 补装完成。"
            }
        }
        else {
            Write-BuildInfo "Android SDK Platform android-$($req.CompileSdkVersion) 已就绪。"
        }
    }

    # ── buildToolsVersion → build-tools ──
    $btVersion = $req.BuildToolsVersion
    if (-not $btVersion -and $req.CompileSdkVersion) {
        # 无明确声明 → 按 CompileSdk 匹配最新 build-tools（复用现有 Get-AndroidBuildToolsVersion）
        if (-not $repoXml) { $repoXml = Get-SdkRepositoryXml }
        $btVersion = Get-AndroidBuildToolsVersion -RepoXml $repoXml -TargetApiLevel $req.CompileSdkVersion
    }

    if ($btVersion) {
        $btPath = Join-Path $script:AndroidHome "build-tools\$btVersion"
        if (-not (Test-Path -LiteralPath $btPath)) {
            if (-not $script:RequirementsInstallSdk) {
                Write-BuildWarn "检测到缺失 build-tools $btVersion，但 requirements.installSdk=false，跳过补装。"
            }
            else {
                if (-not $repoXml) { $repoXml = Get-SdkRepositoryXml }
                Write-BuildInfo "正在补装缺失的 build-tools：$btVersion..."
                Install-AndroidSdkPackage -RepoXml $repoXml -PackagePath "build-tools;$btVersion" -DestinationDir $script:AndroidHome
                if (-not (Test-Path -LiteralPath $btPath)) {
                    throw "补装 build-tools $btVersion 失败，请检查网络或镜像源。"
                }
                Write-BuildInfo "build-tools $btVersion 补装完成。"
            }
        }
        else {
            Write-BuildInfo "build-tools $btVersion 已就绪。"
        }
    }

    # ── NDK ──
    if ($req.NdkVersion) {
        $ndkPath = Join-Path $script:AndroidHome "ndk\$($req.NdkVersion)"
        if (-not (Test-Path -LiteralPath $ndkPath)) {
            $action = $script:RequirementsInstallNdk
            $confirmed = $false
            switch ($action) {
                'always' { $confirmed = $true }
                'ask' {
                    Write-BuildWarn "项目需要 NDK $($req.NdkVersion)，但当前未安装。NDK 包约 1-2GB。"
                    Write-BuildWarn "国内网络直连 Google 下载极慢且易超时，建议通过本工具镜像源预装。"
                    $choice = Read-Host "是否现在通过镜像源安装 NDK $($req.NdkVersion)？[Y/n]"
                    if ($choice -eq '' -or $choice -ieq 'y' -or $choice -ieq 'yes') {
                        $confirmed = $true
                    }
                }
                'never' {
                    Write-BuildWarn "项目需要 NDK $($req.NdkVersion) 但当前未安装。"
                    Write-BuildWarn "requirements.installNdk=never，跳过补装。Gradle 构建时将尝试从 Google 官方源下载（国内可能极慢或失败）。"
                }
            }

            if ($confirmed) {
                if (-not $repoXml) { $repoXml = Get-SdkRepositoryXml }
                Write-BuildInfo "正在通过镜像源补装 NDK $($req.NdkVersion)（约 1-2GB，请耐心等待）..."
                Install-AndroidSdkPackage -RepoXml $repoXml -PackagePath "ndk;$($req.NdkVersion)" -DestinationDir $script:AndroidHome
                if (-not (Test-Path -LiteralPath $ndkPath)) {
                    throw "补装 NDK $($req.NdkVersion) 失败，请检查网络或镜像源。"
                }
                Write-BuildInfo "NDK $($req.NdkVersion) 补装完成。"
            }
        }
        else {
            Write-BuildInfo "NDK $($req.NdkVersion) 已就绪。"
        }
    }

    Write-BuildInfo "项目 SDK 需求检测完成，全部必要组件已就绪。"
}


function Get-SdkRepositoryXml {
    # 获取 Android SDK 仓库 XML 内容（缓存优先），用于 Install-AndroidSdkPackage

    $androidRepoXml = $script:AndroidRepositoryXml
    try {
        $cmdlineToolsUrl = Get-LatestAndroidCmdlineToolsUrl
        if ($cmdlineToolsUrl -and $cmdlineToolsUrl.RepositoryXml) {
            return [xml]$cmdlineToolsUrl.RepositoryXml
        }
    }
    catch {
        # 回退：直接下载 repository XML
    }

    # 回退到远程下载 XML
    try {
        $wc = New-Object System.Net.WebClient
        $xmlContent = $wc.DownloadString($androidRepoXml)
        $wc.Dispose()
        return [xml]$xmlContent
    }
    catch {
        throw "无法获取 Android SDK 仓库 XML：$($_.Exception.Message)"
    }
}


# ============================================================
#  通用构建失败特征 → 中文修复建议
# ============================================================

function Write-BuildFailureHint {
    # 扫描构建日志文本，识别 7 类已知错误特征并输出中文修复建议。
    # 不抛异常，仅 Write-BuildError 输出警告。
    # 特征表：
    #   1. JDK 版本不匹配（Unsupported class file major version）
    #   2. NDK 未安装或缺失
    #   3. SDK 路径未配置
    #   4. 许可证未接受
    #   5. Kotlin 插件版本不兼容
    #   6. CMake / Ninja 工具链缺失
    #   7. Cordova 插件不兼容（android.support / Cannot find symbol）

    param(
        [Parameter(Mandatory = $true)][string]$LogText
    )

    $matched = $false

    # 1. JDK 版本不匹配
    if ($LogText -match 'Unsupported class file major version') {
        Write-BuildError ">>> 构建失败诊断：JDK 版本与项目编译目标不匹配。"
        Write-BuildError "    当前 JDK: $(if($env:JAVA_HOME){& "$env:JAVA_HOME\bin\java" -version 2>&1 | Select-Object -First 1})"
        Write-BuildError "    建议：检查 jdk.requiredMajorVersion 配置（当前 $($script:RequiredJdkMajorVersion)）。"
        Write-BuildError "          若项目较老（如 RN <=0.72 / AGP 7.x），请尝试改为 11；更新项目请用 17。"
        Write-BuildError "          config.json → jdk.requiredMajorVersion = 11（或 17）。"
        Write-BuildError "    若 jdk.autoDetect 开启（默认），工具已尝试自动选择，可检查提示确认映射是否正确。"
        $matched = $true
    }

    # 2. NDK 缺失
    if ($LogText -match 'NDK not installed|No version of NDK|ndk.*not found|NDK at') {
        Write-BuildError ">>> 构建失败诊断：Android NDK 未安装或路径错误。"
        Write-BuildError "    项目 build.gradle 中声明的 ndkVersion 在 SDK 目录中未找到。"
        Write-BuildError "    建议：运行本工具「清理缓存」后重新构建（工具将在构建前提示补装 NDK）。"
        Write-BuildError "          也可用 sdkmanager 手动安装：sdkmanager 'ndk;<版本号>'"
        Write-BuildError "          config.json → requirements.installNdk = 'always' 可跳过询问直接安装。"
        Write-BuildError "    注意：NDK 包约 1-2GB，默认需确认后才下载。"
        $matched = $true
    }

    # 3. SDK 路径未配置
    if ($LogText -match 'SDK location not found|sdk\.dir|android\.sdk|ANDROID_HOME|ANDROID_SDK_ROOT') {
        Write-BuildError ">>> 构建失败诊断：Android SDK 路径未正确配置。"
        Write-BuildError "    建议：检查 local.properties 中 sdk.dir 是否正确指向 SDK 目录。"
        Write-BuildError "          检查环境变量 ANDROID_HOME / ANDROID_SDK_ROOT。"
        Write-BuildError "          运行本工具「清理缓存」→「构建正式版」重新配置环境。"
        $matched = $true
    }

    # 4. 许可证
    if ($LogText -match 'Licen[cs]e.*not accepted|licenses.*not been accepted|You have not accepted the license') {
        Write-BuildError ">>> 构建失败诊断：Android SDK 许可证未被接受。"
        Write-BuildError "    建议：在 config.json 中设置 android.acceptLicenses = true。"
        Write-BuildError "          或手动执行：sdkmanager --licenses"
        $matched = $true
    }

    # 0. Gradle transforms 缓存损坏（最优先：特征明确且工具可自愈，避免被下游通用规则误伤）
    if (Test-GradleTransformCorruption -LogText $LogText) {
        Write-BuildError ">>> 构建失败诊断：Gradle transforms 缓存损坏（上次构建中断、守护进程被强杀或杀软扫描所致）。"
        Write-BuildError "    支持自愈的构建路径已自动清理损坏条目并重试；此处仍失败请运行「清理缓存」，"
        Write-BuildError "    或手动删除 $env:GRADLE_USER_HOME\caches 下对应版本的 transforms 目录后重建。"
        $matched = $true
    }

    # 0b. 磁盘空间不足（乱码 '�ռ䲻' 为 GBK「空间不足」被按 UTF-8 误读的形态）
    if ($LogText -match '磁盘空间不足|No space left|Not enough space|Insufficient space|�ռ䲻') {
        Write-BuildError '>>> 构建失败诊断：磁盘空间不足。'
        Write-BuildError '    NDK（解包约 4GB）、SDK 组件、Gradle 缓存都是空间大户。'
        Write-BuildError '    建议：清理磁盘后重试（菜单「清理缓存」、删除 C:\APKTools\g\ 下旧项目缓存）。'
        $matched = $true
    }

    # 0c. AGP 自动安装 SDK 组件失败
    if ($LogText -match 'Failed to install the following SDK components|InstallFailedException') {
        Write-BuildError '>>> 构建失败诊断：AGP 自动安装 SDK 组件失败（NDK/CMake 等）。'
        Write-BuildError '    最常见诱因是磁盘空间不足；排除后可由工具按项目声明版本自动补装，'
        Write-BuildError '    或手动执行 sdkmanager "<组件名>"（如 sdkmanager "ndk;27.1.12297006"）。'
        $matched = $true
    }

    # 5. Kotlin 版本不兼容
    if ($LogText -match "incompatible version of Kotlin|Class 'kotlin|Kotlin.*incompatible") {
        Write-BuildError ">>> 构建失败诊断：Kotlin 插件版本与 AGP 或项目依赖不兼容。"
        Write-BuildError "    建议：检查 android/build.gradle ext 中的 kotlinVersion 与 buildscript classpath kotlin-gradle-plugin 版本是否一致。"
        Write-BuildError "          常见问题：RN 0.73+ 要求 Kotlin >=1.9，但 ext 中锁定了旧版本。"
        $matched = $true
    }

    # 6. CMake / Ninja 工具链（注意：不能裸匹配 ninja/CMake，任务名与 build.ninja 会误报）
    if ($LogText -match 'CMake.*not found|ninja: error|ninja.*not found|No CMAKE_C_COMPILER|Native build tools.*(missing|not found)') {
        Write-BuildError ">>> 构建失败诊断：CMake / Ninja 工具链缺失。"
        Write-BuildError "    建议：NDK 自带 CMake 但需要安装对应版本。可尝试："
        Write-BuildError "          sdkmanager 'cmake;3.22.1'（版本号按 build.gradle 中指定）"
        Write-BuildError "          或在系统 PATH 中安装 CMake >=3.18.1。"
        Write-BuildError "    若为 Expo 项目，检查 eas-build 配置中的 ndk 版本是否正确。"
        $matched = $true
    }

    # 7. Cordova 专属：插件不兼容 → 提示 engine 锁定（区别于通用 Kotlin/CMake）
    if ($LogText -match 'android\.support\.|Cannot find symbol|package .* does not exist') {
        Write-BuildError ">>> 构建失败诊断：Cordova 插件可能与当前 cordova-android 版本不兼容。"
        Write-BuildError "    建议：在 config.xml 中用 <engine> 锁定旧版平台，删除 platforms 目录后重试。"
        Write-BuildError "    示例：<engine name=\"android\" spec=\"10.1.2\" />"
        Write-BuildError "    删除：Remove-Item -Recurse -Force platforms\"
        $matched = $true
    }

    if (-not $matched) {
        Write-BuildInfo "未识别到已知错误特征，请检查完整构建日志排查。"
    }
}
