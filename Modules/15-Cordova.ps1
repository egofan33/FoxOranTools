#Requires -Version 5.1
#=============================================================================
# 15-Cordova.ps1 - Cordova 项目构建（CLI 安装、平台自愈、SDK 缺失补装、双版本构建）
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================


# =============================================================================
# Cordova CLI 检测与安装（npm 全局安装到便携 Node，会话级 NPM_CONFIG_REGISTRY 镜像）
# =============================================================================

function Test-CordovaCliAvailable {
    [CmdletBinding()]
    param()
    $check = Check-Path -Name 'cordova'
    return $check.Exists
}

function Install-CordovaCli {
    <#
        确保 cordova CLI 可用：PATH 已有则直接复用；否则用便携 Node 的 npm 全局安装
        （-g 前缀落在便携 Node 目录内，天然隔离、不污染系统、无需 UAC）。
        registry 通过会话级 NPM_CONFIG_REGISTRY 环境变量注入（优先级高于 .npmrc，
        不修改用户全局 npm 配置），由 Start-ReleaseBuild 的 originalEnv 备份恢复。
    #>
    [CmdletBinding()]
    param()

    if (Test-CordovaCliAvailable) {
        $version = (& cordova --version 2>&1 | Out-String).Trim()
        Write-BuildInfo "Cordova CLI 已可用：$version"
        return
    }

    Install-PortableNode

    $npmCheck = Check-Path -Name 'npm'
    if (-not $npmCheck.Exists) {
        throw 'Install-CordovaCli: npm 不可用，请检查便携 Node.js 安装。'
    }

    # 会话级 registry 镜像注入（独立调用本函数时兜底；主流程已在环境变量阶段注入）
    if ([string]::IsNullOrWhiteSpace($env:NPM_CONFIG_REGISTRY) -and -not [string]::IsNullOrWhiteSpace($script:CordovaNpmRegistry)) {
        $env:NPM_CONFIG_REGISTRY = $script:CordovaNpmRegistry
        Write-BuildInfo "npm registry 镜像（会话级注入）：$env:NPM_CONFIG_REGISTRY"
    }

    $installSpec = if ([string]::IsNullOrWhiteSpace($script:CordovaCliVersion) -or $script:CordovaCliVersion -eq 'latest') { 'cordova' } else { "cordova@$($script:CordovaCliVersion)" }
    Write-BuildInfo "正在通过 npm 全局安装 $installSpec ..."

    & npm install -g $installSpec 2>&1 | ForEach-Object {
        $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
        Write-Host $line
        if ($null -ne $script:BuildLogWriter) { $script:BuildLogWriter.WriteLine($line) }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Cordova CLI 安装失败，退出码 $LASTEXITCODE。"
    }

    if (-not (Test-CordovaCliAvailable)) {
        throw 'Install-CordovaCli: 安装后 cordova 命令仍不可用（npm 全局目录未加入 PATH）。'
    }

    $version = (& cordova --version 2>&1 | Out-String).Trim()
    Write-BuildInfo "Cordova CLI 安装完成：$version"
}


# =============================================================================
# JDK 自适应（按 cordova-android 版本选择 8/11/17，须在 Install-PortableJdk 前调用）
# =============================================================================

function Get-CordovaAndroidPlatformMajor {
    <#
        确定项目使用的 cordova-android 主版本号。
        顺序：platforms\platforms.json（已添加平台的实际版本，最可靠）
             → package.json 的 cordova-android 依赖声明
             → config.xml 的 <engine name="android" spec="..."/>
        无法确定时返回 $null。
    #>
    [CmdletBinding()]
    param()

    # 1. 已添加平台：platforms\platforms.json 记录实际安装版本
    $platformsJson = Join-Path $script:MobileRoot 'platforms\platforms.json'
    if (Test-Path -LiteralPath $platformsJson) {
        try {
            $data = Get-Content -LiteralPath $platformsJson -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ("$($data.android)" -match '(\d+)') { return [int]$Matches[1] }
        }
        catch { }
    }

    # 2. package.json 依赖声明
    $pkgPath = Join-Path $script:MobileRoot 'package.json'
    if (Test-Path -LiteralPath $pkgPath) {
        try {
            $pkg = Get-Content -LiteralPath $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            foreach ($depSet in @($pkg.dependencies, $pkg.devDependencies)) {
                if ($null -eq $depSet) { continue }
                $prop = $depSet.PSObject.Properties['cordova-android']
                if ($prop -and ("$($prop.Value)" -match '(\d+)\.')) { return [int]$Matches[1] }
            }
        }
        catch { }
    }

    # 3. config.xml <engine name="android" spec="..."/>
    $configXml = Join-Path $script:MobileRoot 'config.xml'
    if (Test-Path -LiteralPath $configXml) {
        try {
            $xmlText = Get-Content -LiteralPath $configXml -Raw -Encoding UTF8
            if ($xmlText -match '<engine\s+[^>]*name\s*=\s*"android"[^>]*spec\s*=\s*"([^"]+)"') {
                if ($Matches[1] -match '(\d+)\.') { return [int]$Matches[1] }
            }
        }
        catch { }
    }

    return $null
}

function Resolve-CordovaJdkMajorVersion {
    <#
        Cordova 项目 JDK 自适应：config cordova.jdkMajorVersion 为数字（8/11/17 等）时强制使用；
        默认 auto 按 cordova-android 版本映射（>=12→17、10~11→11、<=9→8）。
        结果写入 $script:RequiredJdkMajorVersion，必须在 Install-PortableJdk 之前调用。
    #>
    [CmdletBinding()]
    param()

    $configured = "$($script:CordovaJdkMajorVersion)".Trim()
    if ($configured -match '^\d+$') {
        $script:RequiredJdkMajorVersion = [int]$configured
        Write-BuildInfo "Cordova：按配置 cordova.jdkMajorVersion 使用 JDK $configured。"
        return
    }

    $platformMajor = Get-CordovaAndroidPlatformMajor
    if ($null -eq $platformMajor) {
        Write-BuildInfo "Cordova：未能确定 cordova-android 版本（可能尚未添加平台），使用默认 JDK $($script:RequiredJdkMajorVersion)。"
        return
    }

    $jdk = 17
    if ($platformMajor -le 9) { $jdk = 8 }
    elseif ($platformMajor -le 11) { $jdk = 11 }

    Write-BuildInfo "Cordova：检测到 cordova-android $platformMajor.x，自动选择 JDK $jdk。"
    $script:RequiredJdkMajorVersion = $jdk
}


# =============================================================================
# Android 平台自愈（尊重项目锁定版本，绝不主动升级）
# =============================================================================

function Test-CordovaAndroidPlatform {
    [CmdletBinding()]
    param()
    return (Test-Path -LiteralPath (Join-Path $script:MobileRoot 'platforms\android'))
}

function Assert-CordovaAndroidPlatform {
    <#
        确保 Android 平台已添加。
        已存在 platforms\android 时完全不动（避免升级平台破坏旧插件兼容性）；
        缺失时执行 cordova platform add android —— 不带版本号，cordova restore 语义
        自动采用 config.xml <engine> / package.json 中锁定的版本；
        仅当 config cordova.androidPlatformVersion 显式设置时才附加版本号。
    #>
    [CmdletBinding()]
    param()

    if (Test-CordovaAndroidPlatform) {
        Write-BuildInfo 'platforms\android 已存在，沿用项目现有平台版本（不执行升级）。'
        return
    }

    Write-BuildInfo '未检测到 platforms\android，正在添加 Android 平台...'
    Push-Location $script:MobileRoot
    try {
        $addArgs = @('platform', 'add')
        if (-not [string]::IsNullOrWhiteSpace($script:CordovaAndroidPlatformVersion)) {
            $addArgs += "cordova-android@$($script:CordovaAndroidPlatformVersion)"
        }
        else {
            $addArgs += 'android'
        }

        & cordova @addArgs 2>&1 | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
            Write-Host $line
            if ($null -ne $script:BuildLogWriter) { $script:BuildLogWriter.WriteLine($line) }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "cordova platform add 失败，退出码 $LASTEXITCODE。"
        }
    }
    finally {
        Pop-Location
    }

    # platform add 成功后必须修正 AndroidDir：后续 Gradle 优化与 APK 定位依赖该变量
    $script:AndroidDir = Join-Path $script:MobileRoot 'platforms\android'
    if (-not (Test-Path -LiteralPath $script:AndroidDir)) {
        throw "Android 平台添加后仍未找到目录：$($script:AndroidDir)"
    }
    Write-BuildInfo "Android 平台已就绪：$($script:AndroidDir)"
}


# =============================================================================
# SDK 缺失自愈（cordova requirements 驱动）
# =============================================================================

function Get-CordovaRequiredApiLevel {
    <#
        确定 cordova-android 要求的 Android API 级别。
        顺序：platforms\android 下 gradle 文件中的 compileSdk 声明
             → config.xml 的 android-compileSdkVersion / android-targetSdkVersion preference
             → cordova-android 版本映射表（14→35 / 13→34 / 12→33 / 11→32 / 10→30 / 9→29 / 8→28）。
        无法确定时返回 $null。
    #>
    [CmdletBinding()]
    param()

    $gradleFiles = @(
        (Join-Path $script:MobileRoot 'platforms\android\app\build.gradle'),
        (Join-Path $script:MobileRoot 'platforms\android\build.gradle'),
        (Join-Path $script:MobileRoot 'platforms\android\gradle.properties')
    )
    foreach ($file in $gradleFiles) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $content = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        # cordova-android 11+ 默认值：ext.cdvCompileSdkVersion = cdvCompileSdkVersion == null ? 33
        if ($content -match 'cdvCompileSdkVersion\D{0,40}?(\d{2})') { return [int]$Matches[1] }
        # compileSdk = 34 / compileSdkVersion 33 / compileSdkVersion = 33
        if ($content -match '(?m)^\s*compileSdk\s*=\s*(\d{2})') { return [int]$Matches[1] }
        if ($content -match '(?m)^\s*compileSdkVersion\s*=?\s*(\d{2})') { return [int]$Matches[1] }
    }

    # config.xml preference 兜底
    $configXml = Join-Path $script:MobileRoot 'config.xml'
    if (Test-Path -LiteralPath $configXml) {
        $xmlText = Get-Content -LiteralPath $configXml -Raw -Encoding UTF8
        if ($xmlText -match '<preference\s+name\s*=\s*"android-compileSdkVersion"\s+value\s*=\s*"(\d+)"') { return [int]$Matches[1] }
        if ($xmlText -match '<preference\s+name\s*=\s*"android-targetSdkVersion"\s+value\s*=\s*"(\d+)"') { return [int]$Matches[1] }
    }

    # cordova-android 版本映射表兜底
    $platformMajor = Get-CordovaAndroidPlatformMajor
    if ($null -ne $platformMajor) {
        $apiMap = @{ 14 = 35; 13 = 34; 12 = 33; 11 = 32; 10 = 30; 9 = 29; 8 = 28 }
        if ($apiMap.ContainsKey($platformMajor)) { return $apiMap[$platformMajor] }
        if ($platformMajor -gt 14) { return 35 }
    }

    return $null
}

function Install-CordovaMissingRequirements {
    <#
        执行 cordova requirements android 检测构建环境：
        - Android target（SDK Platform）缺失：按 cordova-android 自身要求补装
          platforms;android-N 与匹配 build-tools（镜像源），装完重跑 requirements 复验；
        - 仅系统 Gradle 未检出：cordova-android 使用工程内 gradle wrapper 构建，警告后继续；
        - JDK / SDK 根未检出：环境装配问题，直接抛出中文错误。
        版本一律以 cordova-android 要求为准，不沿用全局 AndroidTargetApiLevel。
    #>
    [CmdletBinding()]
    param()

    Write-BuildInfo '正在执行 cordova requirements android 检测构建环境...'
    Push-Location $script:MobileRoot
    try {
        $reqLog = $null
        & cordova requirements android 2>&1 | Tee-Object -Variable reqLog | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
            Write-Host $line
            if ($null -ne $script:BuildLogWriter) { $script:BuildLogWriter.WriteLine($line) }
        }
        $reqExit = $LASTEXITCODE
        $reqText = ($reqLog | Out-String)

        if ($reqExit -eq 0) {
            Write-BuildInfo 'cordova requirements 检测通过。'
            return
        }

        if ($reqText -match 'Java JDK:\s*not installed') {
            throw 'cordova requirements 未检测到可用的 Java JDK：当前 JDK 版本可能与 cordova-android 不兼容（≤9 需 JDK 8、10~11 需 JDK 11、≥12 需 JDK 17），可在 config.json 设置 cordova.jdkMajorVersion 强制指定后重试。'
        }
        if ($reqText -match 'Android SDK:\s*not installed') {
            throw 'cordova requirements 未检测到 Android SDK（ANDROID_HOME / ANDROID_SDK_ROOT 环境异常）。'
        }

        if ($reqText -match 'Android target:\s*not installed') {
            $apiLevel = Get-CordovaRequiredApiLevel
            if (-not $apiLevel) {
                throw "无法确定 cordova-android 所需的 Android API 级别，请手动安装对应 SDK Platform 后重试。`n$reqText"
            }

            $sdkRoot = $env:ANDROID_SDK_ROOT
            if ([string]::IsNullOrWhiteSpace($sdkRoot)) { $sdkRoot = $env:ANDROID_HOME }
            $platformDir = Join-Path $sdkRoot "platforms\android-$apiLevel"

            if (Test-Path -LiteralPath $platformDir) {
                Write-BuildInfo "SDK Platform android-$apiLevel 已存在，跳过补装。"
            }
            else {
                Write-BuildInfo "cordova-android 需要 SDK Platform android-$apiLevel，正在通过镜像源补装..."
                $repoInfo = Get-LatestAndroidCmdlineToolsUrl
                Install-AndroidSdkPackage -RepoXml $repoInfo.RepositoryXml -PackagePath "platforms;android-$apiLevel" -DestinationDir $platformDir

                $buildToolsVersion = Get-AndroidBuildToolsVersion -RepoXml $repoInfo.RepositoryXml -TargetApiLevel $apiLevel
                if (-not (Test-Path -LiteralPath (Join-Path $sdkRoot "build-tools\$buildToolsVersion"))) {
                    Write-BuildInfo "补装匹配的 build-tools：$buildToolsVersion ..."
                    Install-AndroidSdkPackage -RepoXml $repoInfo.RepositoryXml -PackagePath "build-tools;$buildToolsVersion" -DestinationDir (Join-Path $sdkRoot "build-tools\$buildToolsVersion")
                }
            }

            # 复验
            Write-BuildInfo '补装完成，重新执行 cordova requirements 复验...'
            $reqLog = $null
            & cordova requirements android 2>&1 | Tee-Object -Variable reqLog | ForEach-Object {
                $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
                Write-Host $line
                if ($null -ne $script:BuildLogWriter) { $script:BuildLogWriter.WriteLine($line) }
            }
            $reqExit = $LASTEXITCODE
            $reqText = ($reqLog | Out-String)

            if ($reqExit -eq 0) {
                Write-BuildInfo 'SDK 缺失项已补装，cordova requirements 复验通过。'
                return
            }
        }

        # 收尾判定：仅剩 Gradle 未检出时放行（构建走工程内 wrapper，Gradle 版本由 cordova-android 决定）
        if ($reqExit -ne 0) {
            if ($reqText -match 'Gradle:\s*not installed' -and $reqText -notmatch 'Android target:\s*not installed') {
                Write-BuildWarn 'cordova requirements 未检测到系统 Gradle；cordova-android 将使用工程内 Gradle wrapper 构建，继续。'
                return
            }
            throw "cordova requirements 检测仍未通过，请根据上方输出处理。`n$reqText"
        }
    }
    finally {
        Pop-Location
    }
}


# =============================================================================
# Gradle 引导（cordova-android ≥15 不再捆绑 gradlew）
# =============================================================================

function Get-CordovaGradleVersion {
    <#
        确定引导用 Gradle 版本：
        config gradle.bootstrapVersion 显式指定优先；
        否则读 node_modules\cordova-android\framework\cdv-gradle-config-defaults.json 的
        GRADLE_VERSION（与 cordova-android 构建时写入 wrapper 的版本一致）；
        无法确定时兜底 8.14.2（cordova-android 15.1 的默认值）。
    #>
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($script:GradleBootstrapVersion)) {
        return $script:GradleBootstrapVersion.Trim()
    }

    $defaultsJson = Join-Path $script:MobileRoot 'node_modules\cordova-android\framework\cdv-gradle-config-defaults.json'
    if (Test-Path -LiteralPath $defaultsJson) {
        try {
            $data = Get-Content -LiteralPath $defaultsJson -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ("$($data.GRADLE_VERSION)" -match '^\d+\.\d+(\.\d+)?$') { return "$($data.GRADLE_VERSION)" }
        }
        catch { }
    }

    return '8.14.2'
}

function Set-CordovaGradleDistributionMirror {
    <#
        cordova-android ≥15 的 wrapper 由系统 Gradle 在构建时生成（platforms\android\tools 下），
        无法提前改写 gradle-wrapper.properties；利用官方钩子 CORDOVA_ANDROID_GRADLE_DISTRIBUTION_URL
        让生成的 wrapper 直接指向国内镜像分发地址，避免 services.gradle.org 超时。
        环境变量已由外部显式设置时尊重原值。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GradleVersion)

    if (-not [string]::IsNullOrWhiteSpace($env:CORDOVA_ANDROID_GRADLE_DISTRIBUTION_URL)) {
        Write-BuildInfo "沿用已有 CORDOVA_ANDROID_GRADLE_DISTRIBUTION_URL：$env:CORDOVA_ANDROID_GRADLE_DISTRIBUTION_URL"
        return
    }

    $mirrors = @(
        @{ Name = '华为云'; Url = "https://mirrors.huaweicloud.com/gradle/gradle-$GradleVersion-bin.zip" }
        @{ Name = '腾讯云'; Url = "https://mirrors.cloud.tencent.com/gradle/gradle-$GradleVersion-bin.zip" }
    )
    foreach ($mirror in $mirrors) {
        Write-BuildInfo "探测 $($mirror.Name) Gradle 镜像连通性..."
        try {
            $iwrSplat = @{ Uri = $mirror.Url; Method = 'Head'; TimeoutSec = 10; ErrorAction = 'Stop' }
            if ($PSVersionTable.PSVersion.Major -le 5) { $iwrSplat['UseBasicParsing'] = $true }
            Invoke-WebRequest @iwrSplat | Out-Null
            $env:CORDOVA_ANDROID_GRADLE_DISTRIBUTION_URL = $mirror.Url
            Write-BuildInfo "Gradle wrapper 分发地址（$($mirror.Name) 镜像）：$($mirror.Url)"
            return
        }
        catch {
            Write-BuildWarn "$($mirror.Name) 镜像不可达：$($_.Exception.Message)"
        }
    }
    Write-BuildWarn '国内 Gradle 镜像均不可达，wrapper 将使用 services.gradle.org 官方源（可能较慢）。'
}


# =============================================================================
# 构建与输出
# =============================================================================

function Invoke-CordovaBuild {
    <#
        执行 cordova build android [--release]，输出实时落控制台与构建日志，退出码检查。
        失败时按输出特征附中文提示：JDK 与平台不匹配 / 插件与平台版本不兼容。
    #>
    [CmdletBinding()]
    param(
        [switch]$Release
    )

    $buildType = if ($Release) { 'release' } else { 'debug' }
    # cordova-android ≥15 破坏性变更：未显式指定时 release 默认产出 AAB（bundle），
    # 与工具箱的 zipalign + apksigner APK 签名管线不兼容，必须显式锁定 apk。
    # 平台级选项必须放在 `--` 之后：cordova CLI 仅将 `--` 后的参数装入 options.argv
    # 透传给平台（cli.js opts.options.argv = unparsedArgs），cordova-android 的 parseOpts
    # 只从该数组二次解析 packageType；直接跟在命令后会被 CLI 吞掉，静默回退 bundle。
    $buildArgs = @('build', 'android')
    if ($Release) { $buildArgs += '--release' }
    $buildArgs += @('--', '--packageType=apk')

    Write-BuildInfo "正在执行 cordova build android（$buildType，首次构建需下载 Gradle 与依赖，耗时较长）..."
    Push-Location $script:MobileRoot
    try {
        $buildLog = $null
        & cordova @buildArgs 2>&1 | Tee-Object -Variable buildLog | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
            Write-Host $line
            if ($null -ne $script:BuildLogWriter) { $script:BuildLogWriter.WriteLine($line) }
        }
        $exitCode = $LASTEXITCODE
        $buildText = ($buildLog | Out-String)

        if ($exitCode -ne 0) {
            Write-BuildFailureHint -LogText $buildText
            throw "Cordova $buildType 构建失败，退出码 $exitCode。详见构建日志：$($script:BuildLogPath)"
        }

        Write-BuildInfo "Cordova $buildType 构建成功。"
    }
    finally {
        Pop-Location
    }
}

function Get-CordovaOutputApk {
    <#
        定位 cordova build 产出的 APK：release 优先 *-unsigned.apk，debug 排除 unaligned；
        兼容 cordova-android ≤6 的旧布局 platforms\android\build\outputs\apk。
    #>
    [CmdletBinding()]
    param(
        [switch]$Release
    )

    $variant = if ($Release) { 'release' } else { 'debug' }
    $apkDir = Join-Path $script:AndroidDir "app\build\outputs\apk\$variant"
    $legacyDir = Join-Path $script:AndroidDir "build\outputs\apk\$variant"
    if (-not (Test-Path -LiteralPath $apkDir) -and (Test-Path -LiteralPath $legacyDir)) {
        $apkDir = $legacyDir
    }
    if (-not (Test-Path -LiteralPath $apkDir)) {
        throw "未找到 Cordova $variant APK 输出目录：$apkDir"
    }

    $apks = @(Get-ChildItem -LiteralPath $apkDir -Filter '*.apk' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'unaligned' } |
        Sort-Object LastWriteTime -Descending)
    if (-not $apks) {
        throw "Cordova $variant 构建完成，但未找到 APK：$apkDir"
    }

    if ($Release) {
        $unsigned = $apks | Where-Object { $_.Name -match 'unsigned' } | Select-Object -First 1
        if ($unsigned) { return $unsigned.FullName }
    }
    return $apks[0].FullName
}

function Build-CordovaAllApks {
    <#
        Cordova 构建主流程：CLI 就绪 → 平台自愈 → SDK 缺失补装 → Gradle 版本中立优化
        → release 构建后走现有签名流程输出 app-release.apk
        → cordova.buildDebug 为真时 debug 构建直出 app-debug.apk（自带 debug 签名，不重复签名）。
        调用前提：Start-ReleaseBuild 已完成 JDK/Node/SDK 安装、环境变量注入与 Node 依赖就绪。
    #>
    [CmdletBinding()]
    param()

    Write-BuildInfo '======== Cordova Android 构建 ========'

    Install-CordovaCli
    Assert-CordovaAndroidPlatform

    # cordova-android ≥15 不再捆绑 gradlew：构建时需 PATH 上的系统 Gradle 引导生成 wrapper；
    # 版本与 cordova-android 期望的 GRADLE_VERSION 对齐
    $gradleVersion = Get-CordovaGradleVersion
    Install-PortableGradle -Version $gradleVersion | Out-Null

    Install-CordovaMissingRequirements

    # 写入 local.properties（ANDROID_HOME 之外的保险，Gradle 插件同样读取该文件）
    $sdkRoot = $env:ANDROID_SDK_ROOT
    if ([string]::IsNullOrWhiteSpace($sdkRoot)) { $sdkRoot = $env:ANDROID_HOME }
    Set-Content -LiteralPath (Join-Path $script:AndroidDir 'local.properties') `
        -Value "sdk.dir=$(Convert-ToGradlePath $sdkRoot)" `
        -Encoding ASCII -Force -ErrorAction Stop

    # Gradle 优化：≤14 自带 wrapper 于平台根 —— 仅替换镜像 host（保留原版本号）；
    # ≥15 wrapper 由系统 Gradle 每次构建时重新生成于 tools\ 下 —— 必须常驻
    # CORDOVA_ANDROID_GRADLE_DISTRIBUTION_URL 指定镜像分发地址（生成时被读取），
    # 并同步修正平台根与 tools\ 下已生成的 wrapper 文件；
    # 仓库镜像走全局 init.gradle（不改项目文件）、4G 堆写项目 gradle.properties
    Set-CordovaGradleDistributionMirror -GradleVersion $gradleVersion
    foreach ($wrapperProps in @(
        (Join-Path $script:AndroidDir 'gradle\wrapper\gradle-wrapper.properties'),
        (Join-Path $script:AndroidDir 'tools\gradle\wrapper\gradle-wrapper.properties'))) {
        if (Test-Path -LiteralPath $wrapperProps) {
            Set-GradleWrapperMirror -WrapperPropsPath $wrapperProps
        }
    }
    Set-GradleMemory
    Set-GradleMirror

    # 正式版：构建 → 现有签名流程（zipalign → apksigner → 校验 → 复制）
    Write-BuildInfo '>>> 构建正式版（release）...'
    Invoke-CordovaBuild -Release
    $unsignedApk = Get-CordovaOutputApk -Release
    Write-BuildInfo "找到待签名 APK：$unsignedApk"
    $finalApk = Invoke-ApkSignAndPublish -UnsignedApkPath $unsignedApk -JavaHome $env:JAVA_HOME -SdkRoot $sdkRoot -BaseName 'app-release.apk'

    # 调试版：自带 debug 签名，直接输出
    if ($script:CordovaBuildDebug) {
        Write-BuildInfo '>>> 构建调试版（debug）...'
        Invoke-CordovaBuild
        $debugApk = Get-CordovaOutputApk
        $debugFinal = Copy-ApkToRelease -SourceApk $debugApk -BaseName 'app-debug.apk'
        Write-BuildInfo "调试版 APK 已输出（自带 debug 签名）：$debugFinal"
    }

    Write-BuildInfo '======== Cordova 构建完成 ========'
}
