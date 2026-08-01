#Requires -Version 5.1
#=============================================================================
# 06-Installers.ps1 - 便携依赖安装器
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================

# =============================================================================
# 便携依赖安装：JDK / Node.js / Android SDK
# =============================================================================

function Install-PortableJdk {
    $localJdkHome = Join-Path $script:GlobalToolsRoot "jdk\$($script:RequiredJdkMajorVersion)"
    $localJavaExe = Join-Path $localJdkHome "bin\java.exe"

    # 1. 优先检测 C:\APKTools\jdk\21，满足版本时直接提到 PATH 最前，避免再检索系统 PATH
    if (Test-Path -LiteralPath $localJavaExe) {
        $major = Get-JavaMajorVersion -JavaExe $localJavaExe
        if ($major -eq $script:RequiredJdkMajorVersion) {
            Write-BuildInfo "检测到本地 JDK $major 满足要求：$localJdkHome"
            Add-PortablePath -Directory "$localJdkHome\bin" -HomeVariable "JAVA_HOME" -HomeValue $localJdkHome
            return $localJdkHome
        }
        else {
            Write-BuildWarn "本地 JDK 主版本为 $major，不满足要求，将重新下载 JDK $($script:RequiredJdkMajorVersion)。"
        }
    }

    # 2. 本地不满足时，再检测系统 PATH
    $check = Check-Path -Name "java"
    if ($check.Exists) {
        $javaExe = $check.Path
        $major = Get-JavaMajorVersion -JavaExe $javaExe
        if ($major -eq $script:RequiredJdkMajorVersion) {
            $homeDir = Split-Path -Parent (Split-Path -Parent $javaExe)
            Write-BuildInfo "检测到系统 PATH 中可用 JDK $major`: $homeDir"
            Add-PortablePath -Directory "$homeDir\bin" -HomeVariable "JAVA_HOME" -HomeValue $homeDir
            return $homeDir
        }
        else {
            Write-BuildWarn "系统 PATH 检测到 Java 但主版本为 $major，将下载便携 JDK $($script:RequiredJdkMajorVersion)。"
        }
    }

    Write-BuildInfo "未检测到兼容 JDK，正在获取 JDK $($script:RequiredJdkMajorVersion) 下载候选..."
    Assert-GlobalToolsRoot
    $candidates = Get-TemurinJdkCandidates
    if (-not $candidates) {
        throw "Install-PortableJdk: 没有可用的 JDK 下载候选源。"
    }

    $successfulCandidate = $null
    $zipPath = $null
    foreach ($candidate in $candidates) {
        Write-BuildInfo "尝试从 [$($candidate.Source)] 下载 JDK..."
        $candidateZipPath = Join-Path $script:GlobalToolsRoot $candidate.Name
        try {
            Download-File -Url $candidate.Url -Destination $candidateZipPath -ExpectedSha256 $candidate.Sha256
            if (-not (Test-ZipArchiveIntegrity -Path $candidateZipPath)) {
                Remove-Item -LiteralPath $candidateZipPath -Force -ErrorAction SilentlyContinue
                throw "JDK 压缩包校验失败（文件被截断，或被代理替换为错误页面）。"
            }
            $zipPath = $candidateZipPath
            $successfulCandidate = $candidate
            break
        }
        catch {
            Write-BuildWarn "候选源 [$($candidate.Source)] 失败：$($_.Exception.Message)"
        }
    }

    if (-not $zipPath) {
        throw @"
Install-PortableJdk: 所有 JDK 下载候选源均失败。
请手动下载 JDK $($script:RequiredJdkMajorVersion) Windows x64 zip 并解压到：$localJdkHome
官方下载页：https://adoptium.net/temurin/releases/?version=$($script:RequiredJdkMajorVersion)
"@
    }

    $extractTmp = Join-Path $script:GlobalToolsRoot "jdk-tmp"
    if (Test-Path -LiteralPath $extractTmp) {
        Remove-Item -LiteralPath $extractTmp -Recurse -Force
    }
    Expand-ArchiveRobust -Path $zipPath -DestinationPath $extractTmp -Force

    $inner = Get-ChildItem -LiteralPath $extractTmp -Directory | Select-Object -First 1
    if (-not $inner) {
        throw "Install-PortableJdk: 解压后未找到 JDK 目录。"
    }

    $jdkHome = $localJdkHome
    if (Test-Path -LiteralPath $jdkHome) {
        Remove-Item -LiteralPath $jdkHome -Recurse -Force
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $jdkHome) -Force | Out-Null
    Move-Item -LiteralPath $inner.FullName -Destination $jdkHome -Force -ErrorAction Stop
    Remove-Item -LiteralPath $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    Add-PortablePath -Directory "$jdkHome\bin" -HomeVariable "JAVA_HOME" -HomeValue $jdkHome
    $versionText = if ($successfulCandidate.Version) { " $($successfulCandidate.Version)" } else { "" }
    Write-BuildInfo "JDK$versionText 已安装到 $jdkHome"
    return $jdkHome
}


function Find-ExistingNodeVersionHome {
    <#
        在 C:\APKTools\node 下查找满足目标版本的已安装 Node.js 目录。
        返回目录全路径，找不到返回 $null。
    #>
    param([Parameter(Mandatory = $true)][string]$Target)

    $nodeRoot = Join-Path $script:GlobalToolsRoot "node"
    if (-not (Test-Path -LiteralPath $nodeRoot)) {
        return $null
    }

    $dirs = Get-ChildItem -LiteralPath $nodeRoot -Directory -ErrorAction SilentlyContinue
    foreach ($dir in $dirs) {
        $nodeExe = Join-Path $dir.FullName "node.exe"
        if (-not (Test-Path -LiteralPath $nodeExe)) { continue }

        $psi = New-Object System.Diagnostics.ProcessStartInfo($nodeExe, '--version')
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $version = ($proc.StandardOutput.ReadLine()).Trim()
        $proc.WaitForExit()

        if (Test-VersionMatchesTarget -Version $version -Target $Target) {
            return $dir.FullName
        }
    }

    return $null
}

function Install-PortableNode {
    $nodeRoot = Join-Path $script:GlobalToolsRoot "node"
    $target = Get-TargetNodeVersion

    # 1. 优先检测 C:\APKTools\node 下已安装的版本
    $existingHome = Find-ExistingNodeVersionHome -Target $target
    if ($existingHome) {
        Write-BuildInfo "检测到本地 Node.js 满足目标版本 $target`: $existingHome"
        Add-PortablePath -Directory $existingHome
        return
    }

    # 2. 本地不满足时，再检测系统 PATH
    $check = Check-Path -Name "node"
    if ($check.Exists) {
        $version = (& node.exe --version 2>&1 | Select-Object -First 1)
        if (Test-VersionMatchesTarget -Version $version -Target $target) {
            Write-BuildInfo "检测到系统 PATH 中 Node.js $version 满足目标版本 $target"
            return
        }
        else {
            Write-BuildWarn "系统 PATH 中 Node.js $version 不满足目标版本 $target，将下载便携版。"
        }
    }

    Write-BuildInfo "未检测到满足目标版本 $target 的 Node.js，正在下载..."
    Assert-GlobalToolsRoot
    $info = Get-LatestNodeUrl
    $zipPath = Join-Path $script:GlobalToolsRoot $info.Name
    Download-File -Url $info.Url -Destination $zipPath
    if (-not (Test-ZipArchiveIntegrity -Path $zipPath)) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        throw "Install-PortableNode: Node.js 压缩包校验失败（文件被截断或被替换为错误页面），请重试。"
    }

    $extractTmp = Join-Path $script:GlobalToolsRoot "node-tmp"
    if (Test-Path -LiteralPath $extractTmp) {
        Remove-Item -LiteralPath $extractTmp -Recurse -Force
    }
    Expand-ArchiveRobust -Path $zipPath -DestinationPath $extractTmp -Force

    $inner = Get-ChildItem -LiteralPath $extractTmp -Directory | Select-Object -First 1
    if (-not $inner) {
        throw "Install-PortableNode: 解压后未找到 Node 目录。"
    }

    # 使用不带 v 前缀的干净版本号作为目录名，例如 20.11.0
    $cleanVersion = $info.Version -replace '^v', ''
    $nodeHome = Join-Path $nodeRoot $cleanVersion

    if (Test-Path -LiteralPath $nodeHome) {
        Remove-Item -LiteralPath $nodeHome -Recurse -Force
    }
    New-Item -ItemType Directory -Path $nodeRoot -Force | Out-Null
    Move-Item -LiteralPath $inner.FullName -Destination $nodeHome -Force -ErrorAction Stop
    Remove-Item -LiteralPath $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    Add-PortablePath -Directory $nodeHome
    Write-BuildInfo "Node.js $info.Version 已安装到 $nodeHome"
}

function Install-PortableGradle {
    <#
        确保 gradle 命令可用（cordova-android ≥15 不再捆绑 gradlew，
        构建时需 PATH 上的系统 Gradle 执行 `gradle -p tools wrapper` 引导生成 wrapper）：
        1. 全局工具目录 gradle\<Version> 已装：注入 PATH；
        2. 系统 PATH 已有 gradle：直接复用（仅引导 wrapper，无严格版本要求）；
        3. 均缺失：经国内镜像（华为云/腾讯云）下载 bin zip（约 130MB）解压注入。
        -Version 期望与 cordova-android 的 GRADLE_VERSION 对齐（见 Get-CordovaGradleVersion）。
    #>
    param([Parameter(Mandatory = $true)][string]$Version)

    $gradleRoot = Join-Path $script:GlobalToolsRoot 'gradle'
    $localHome  = Join-Path $gradleRoot $Version

    # 1. 本地已安装目标版本
    if (Test-Path -LiteralPath (Join-Path $localHome 'bin\gradle.bat')) {
        Write-BuildInfo "检测到本地 Gradle：$localHome"
        Add-PortablePath -Directory (Join-Path $localHome 'bin')
        return $localHome
    }

    # 2. 系统 PATH 已有 gradle
    $check = Check-Path -Name 'gradle'
    if ($check.Exists) {
        Write-BuildInfo "检测到系统 PATH 中 Gradle：$($check.Path)"
        return $null
    }

    Write-BuildInfo "未检测到 Gradle，正在下载便携版 $Version（cordova-android ≥15 构建需要，约 130MB）..."
    Assert-GlobalToolsRoot

    $zipName = "gradle-$Version-bin.zip"
    $zipPath = Join-Path $script:GlobalToolsRoot $zipName
    $mirrors = @(
        @{ Name = '华为云'; Url = "https://mirrors.huaweicloud.com/gradle/$zipName" }
        @{ Name = '腾讯云'; Url = "https://mirrors.cloud.tencent.com/gradle/$zipName" }
    )

    $downloaded = $false
    foreach ($mirror in $mirrors) {
        Write-BuildInfo "尝试从 $($mirror.Name) 镜像下载 Gradle..."
        try {
            Download-File -Url $mirror.Url -Destination $zipPath
            if (-not (Test-ZipArchiveIntegrity -Path $zipPath)) {
                Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
                throw 'Gradle 压缩包校验失败（文件被截断，或被代理替换为错误页面）。'
            }
            $downloaded = $true
            break
        }
        catch {
            Write-BuildWarn "$($mirror.Name) 镜像下载失败：$($_.Exception.Message)"
        }
    }
    if (-not $downloaded) {
        throw "Install-PortableGradle: 所有 Gradle 镜像均下载失败。请手动下载 $zipName 并解压到：$localHome"
    }

    $extractTmp = Join-Path $script:GlobalToolsRoot 'gradle-tmp'
    if (Test-Path -LiteralPath $extractTmp) {
        Remove-Item -LiteralPath $extractTmp -Recurse -Force
    }
    Expand-ArchiveRobust -Path $zipPath -DestinationPath $extractTmp -Force

    $inner = Get-ChildItem -LiteralPath $extractTmp -Directory | Select-Object -First 1
    if (-not $inner -or -not (Test-Path -LiteralPath (Join-Path $inner.FullName 'bin\gradle.bat'))) {
        throw 'Install-PortableGradle: 解压后未找到 bin\gradle.bat。'
    }

    if (Test-Path -LiteralPath $localHome) {
        Remove-Item -LiteralPath $localHome -Recurse -Force
    }
    New-Item -ItemType Directory -Path $gradleRoot -Force | Out-Null
    Move-Item -LiteralPath $inner.FullName -Destination $localHome -Force -ErrorAction Stop
    Remove-Item -LiteralPath $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    Add-PortablePath -Directory (Join-Path $localHome 'bin')
    Write-BuildInfo "Gradle $Version 已安装到 $localHome"
    return $localHome
}

function Find-PortableGitHome {
    <#
        在全局工具目录 git\ 下查找便携 MinGit（cmd\git.exe 存在即有效）。
        返回安装根目录全路径，找不到返回 $null。
    #>
    $gitRoot = Join-Path $script:GlobalToolsRoot 'git'
    if (-not (Test-Path -LiteralPath $gitRoot)) { return $null }

    $candidate = Get-ChildItem -LiteralPath $gitRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'cmd\git.exe') } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function Install-PortableGit {
    <#
        确保 git 命令可用（Flutter 工具链运行时硬性依赖，flutter.bat 启动时 WHERE git 检查）：
        1. 系统 PATH 已有 git：直接使用；
        2. 全局工具目录已有便携 MinGit：注入 PATH；
        3. 均缺失：下载 MinGit zip（约 40MB，官方最小化便携版）解压注入。
    #>
    $check = Check-Path -Name 'git'
    if ($check.Exists) {
        return
    }

    $localHome = Find-PortableGitHome
    if ($localHome) {
        Write-BuildInfo "检测到本地便携 Git：$localHome"
        Add-PortablePath -Directory (Join-Path $localHome 'cmd')
        return
    }

    Assert-GlobalToolsRoot
    $zipPath = Join-Path $script:GlobalToolsRoot 'mingit-portable.zip'

    # 已存在且完整的 zip 直接复用（上次下载完成但后续步骤中断的场景），不完整才重新下载
    $needDownload = $true
    if ((Test-Path -LiteralPath $zipPath) -and (Test-ZipArchiveIntegrity -Path $zipPath)) {
        Write-BuildInfo "复用已存在的 MinGit 压缩包：$zipPath"
        $needDownload = $false
    }

    if ($needDownload) {
        Write-BuildInfo '未检测到 Git，正在下载便携版 MinGit（Flutter 工具链依赖，约 46MB）...'

        # github.com 国内直连基本不通：优先拼接 gh-proxy 镜像下载，镜像失败再回退直连
        # （与 Flutter SDK zip 的"镜像优先、官方兜底"策略一致）
        $directUrl = $script:MinGitDownloadUrl
        $mirrorUrl = $directUrl
        if (-not [string]::IsNullOrEmpty($script:ProxyPrefix) -and -not $directUrl.StartsWith($script:ProxyPrefix)) {
            $mirrorUrl = "$($script:ProxyPrefix)$directUrl"
        }
        $downloaded = $false
        if ($mirrorUrl -ne $directUrl) {
            try {
                Download-File -Url $mirrorUrl -Destination $zipPath
                $downloaded = $true
            }
            catch {
                Write-BuildWarn "镜像下载失败，回退 GitHub 直连：$directUrl"
            }
        }
        if (-not $downloaded) {
            Download-File -Url $directUrl -Destination $zipPath
        }
    }

    if (-not (Test-ZipArchiveIntegrity -Path $zipPath)) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        throw @"
Install-PortableGit: MinGit 压缩包校验失败（文件被截断或被替换为错误页面），请重试。
也可手动安装 Git for Windows（https://git-scm.com/download/win）后重跑。
"@
    }

    # MinGit zip 内容直接位于压缩包根（cmd\、bin\、usr\ 等），解压至目标目录即可
    $gitHome = Join-Path $script:GlobalToolsRoot 'git\mingit'
    if (Test-Path -LiteralPath $gitHome) {
        Remove-Item -LiteralPath $gitHome -Recurse -Force
    }
    Expand-ArchiveRobust -Path $zipPath -DestinationPath $gitHome -Force
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath (Join-Path $gitHome 'cmd\git.exe'))) {
        throw 'Install-PortableGit: 解压后未找到 cmd\git.exe。'
    }

    Add-PortablePath -Directory (Join-Path $gitHome 'cmd')
    Write-BuildInfo "便携 Git 已安装到 $gitHome"
}

function Find-PortableFlutterSdkHome {
    <#
        在全局工具目录 flutter\ 下查找已安装的 Flutter SDK（取最新修改的版本目录）。
        返回 SDK 根目录全路径，找不到返回 $null。
    #>
    $flutterRoot = Join-Path $script:GlobalToolsRoot 'flutter'
    if (-not (Test-Path -LiteralPath $flutterRoot)) { return $null }

    # 按版本号降序选择（目录名即版本号，如 3.24.0）；无法解析版本号的目录按 0.0 排最后，
    # 同版本再以修改时间兜底，保证多版本共存时稳定选中最新版
    $candidate = Get-ChildItem -LiteralPath $flutterRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\flutter.bat') } |
        Sort-Object @{
            Expression = { try { [version]($_.Name -replace '^v', '') } catch { [version]'0.0' } }
            Descending = $true
        }, @{
            Expression = 'LastWriteTime'
            Descending = $true
        } |
        Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function Install-PortableFlutterSdk {
    <#
        确保 Flutter SDK 可用，返回 SDK 根目录：
        1. 检测全局工具目录已安装的便携版；
        2. 检测系统 PATH 中的 flutter；
        3. 检测 FLUTTER_ROOT；
        4.         均缺失时经国内镜像下载 stable 便携版至 全局工具目录\flutter\<version>。
        Flutter 工具链硬性依赖 Git：优先系统 PATH，缺失时自动安装便携 MinGit。
    #>
    # Flutter 工具链硬性依赖 Git（flutter.bat 启动时 WHERE git 检查），
    # 系统没有则自动下载便携 MinGit，全程无需用户预装
    Install-PortableGit

    # 1. 全局工具目录已安装的便携版
    $localHome = Find-PortableFlutterSdkHome
    if ($localHome) {
        Write-BuildInfo "检测到本地 Flutter SDK：$localHome"
        Add-PortablePath -Directory (Join-Path $localHome 'bin')
        return $localHome
    }

    # 2. 系统 PATH
    $flutterCheck = Check-Path -Name 'flutter'
    if ($flutterCheck.Exists) {
        $flutterHome = Split-Path -Parent (Split-Path -Parent $flutterCheck.Path)
        Write-BuildInfo "检测到系统 PATH 中 Flutter SDK：$flutterHome"
        return $flutterHome
    }

    # 3. FLUTTER_ROOT
    if (-not [string]::IsNullOrWhiteSpace($env:FLUTTER_ROOT) -and
        (Test-Path -LiteralPath (Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat'))) {
        Write-BuildInfo "检测到 FLUTTER_ROOT 指向的 Flutter SDK：$env:FLUTTER_ROOT"
        Add-PortablePath -Directory (Join-Path $env:FLUTTER_ROOT 'bin')
        return $env:FLUTTER_ROOT
    }

    # 4. 下载便携版（zip 约 1GB：缓存到 GlobalCacheRoot，重复运行可复用）
    Write-BuildInfo '未检测到 Flutter SDK，正在通过国内镜像下载 stable 便携版（约 1GB，首次较慢）...'
    Assert-GlobalToolsRoot
    $info = Get-FlutterSdkReleaseInfo
    Write-BuildInfo "Flutter stable 版本：$($info.Version)"

    $cacheDir = Join-Path $script:GlobalCacheRoot 'flutter'
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    $zipName = Split-Path $info.ArchiveUrl -Leaf
    $zipPath = Join-Path $cacheDir $zipName

    $needDownload = $true
    if ((Test-Path -LiteralPath $zipPath) -and (Test-ZipArchiveIntegrity -Path $zipPath)) {
        Write-BuildInfo "复用已缓存的 Flutter SDK 压缩包：$zipPath"
        $needDownload = $false
    }
    if ($needDownload) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        try {
            Download-File -Url $info.ArchiveUrl -Destination $zipPath -ExpectedSha256 $info.Sha256
        }
        catch {
            $officialUrl = $info.ArchiveUrl -replace [regex]::Escape(([System.Uri]$info.ArchiveUrl).Host), 'storage.googleapis.com'
            if ($officialUrl -ne $info.ArchiveUrl) {
                Write-BuildWarn "镜像下载失败，回退官方源：$officialUrl"
                Download-File -Url $officialUrl -Destination $zipPath -ExpectedSha256 $info.Sha256
            }
            else {
                throw
            }
        }
        if (-not (Test-ZipArchiveIntegrity -Path $zipPath)) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            throw "Install-PortableFlutterSdk: Flutter SDK 压缩包校验失败（文件被截断或被替换为错误页面），请重试。"
        }
    }

    $extractTmp = Join-Path $cacheDir 'extract-tmp'
    if (Test-Path -LiteralPath $extractTmp) {
        Remove-Item -LiteralPath $extractTmp -Recurse -Force
    }
    Expand-ArchiveRobust -Path $zipPath -DestinationPath $extractTmp -Force

    # Flutter 官方 zip 内层目录名为 flutter
    $inner = Get-ChildItem -LiteralPath $extractTmp -Directory | Select-Object -First 1
    if (-not $inner -or -not (Test-Path -LiteralPath (Join-Path $inner.FullName 'bin\flutter.bat'))) {
        throw 'Install-PortableFlutterSdk: 解压后未找到 Flutter SDK 目录。'
    }

    $flutterRootDir = Join-Path $script:GlobalToolsRoot 'flutter'
    $flutterHome = Join-Path $flutterRootDir $info.Version
    if (Test-Path -LiteralPath $flutterHome) {
        Remove-Item -LiteralPath $flutterHome -Recurse -Force
    }
    New-Item -ItemType Directory -Path $flutterRootDir -Force | Out-Null
    Move-Item -LiteralPath $inner.FullName -Destination $flutterHome -Force -ErrorAction Stop
    Remove-Item -LiteralPath $extractTmp -Recurse -Force -ErrorAction SilentlyContinue

    Add-PortablePath -Directory (Join-Path $flutterHome 'bin')
    Write-BuildInfo "Flutter SDK $($info.Version) 已安装到 $flutterHome"
    return $flutterHome
}

function Install-AndroidSdkPackage {
    <#
        从 Android 仓库 XML 解析指定包，使用镜像/官方源下载 zip 并解压到目标目录。
    #>
    param(
        [Parameter(Mandatory = $true)][xml]$RepoXml,
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$DestinationDir
    )

    $escapedPackagePath = $PackagePath -replace "'", "''"
    $pkg = $RepoXml.SelectSingleNode("//remotePackage[@path='$escapedPackagePath']")
    if (-not $pkg) {
        throw "在 Android 仓库 XML 中未找到包：$PackagePath"
    }

    $archive = $pkg.archives.archive |
        Where-Object { $_.'host-os' -eq "windows" -or -not $_.'host-os' } |
        Select-Object -First 1

    if (-not $archive -or -not $archive.complete.url) {
        throw "未找到 $PackagePath 的 Windows 归档。"
    }

    $url = $archive.complete.url
    if ($url -notmatch '^https?://') {
        if ($script:AndroidUseMirror) {
            $url = "$($script:AndroidMirrorBase.TrimEnd('/'))/$url"
        }
        else {
            $url = "https://dl.google.com/android/repository/$url"
        }
    }
    elseif ($script:AndroidUseMirror) {
        $url = $url -replace '^https?://dl\.google\.com/android/repository', $script:AndroidMirrorBase.TrimEnd('/')
    }

    $zipName = Split-Path $url -Leaf
    $zipPath = Join-Path $script:GlobalToolsRoot $zipName

    Write-BuildInfo "下载 $PackagePath => $zipName"
    Download-File -Url $url -Destination $zipPath -TimeoutSec $script:AndroidSdkDownloadTimeoutSec
    if (-not (Test-ZipArchiveIntegrity -Path $zipPath)) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        throw "Install-AndroidSdkPackage: $PackagePath 压缩包校验失败（文件被截断或被替换为错误页面），请重试。"
    }

    $extractTmp = Join-Path $script:GlobalToolsRoot "android-pkg-tmp"
    if (Test-Path -LiteralPath $extractTmp) {
        Remove-Item -LiteralPath $extractTmp -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractTmp -Force | Out-Null
    Expand-ArchiveRobust -Path $zipPath -DestinationPath $extractTmp -Force

    $inner = Get-ChildItem -LiteralPath $extractTmp -Directory | Select-Object -First 1
    if (-not $inner) {
        throw "解压 $PackagePath 后未找到目录。"
    }

    if (Test-Path -LiteralPath $DestinationDir) {
        Remove-Item -LiteralPath $DestinationDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $DestinationDir) -Force | Out-Null
    Move-Item -LiteralPath $inner.FullName -Destination $DestinationDir -Force -ErrorAction Stop

    Remove-Item -LiteralPath $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
}

function Install-PortableAndroidSdk {
    $globalSdkRoot = Join-Path $script:GlobalToolsRoot "android-sdk"

    # 优先复用已配置或已下载的 SDK
    $candidates = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME, $globalSdkRoot)
    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $hasPlatformTools  = Test-Path -LiteralPath (Join-Path $candidate "platform-tools")
        $hasBuildTools     = Test-Path -LiteralPath (Join-Path $candidate "build-tools")
        $hasTargetPlatform = Test-Path -LiteralPath (Join-Path $candidate "platforms\android-$($script:AndroidTargetApiLevel)")
        if ($hasPlatformTools -and $hasBuildTools -and $hasTargetPlatform) {
            Write-BuildInfo "复用现有 Android SDK：$candidate"
            Add-PortablePath -Directory "$candidate\platform-tools" -HomeVariable "ANDROID_HOME" -HomeValue $candidate
            $cmdlineBin = Join-Path $candidate "cmdline-tools\latest\bin"
            if (Test-Path -LiteralPath $cmdlineBin) {
                Add-PortablePath -Directory $cmdlineBin -HomeVariable "ANDROID_SDK_ROOT" -HomeValue $candidate
            }
            else {
                [System.Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", $candidate, [System.EnvironmentVariableTarget]::Process)
                Write-BuildWarn "现有 SDK 缺少 cmdline-tools，后续将尝试安装。"
            }
            return $candidate
        }
    }

    Write-BuildInfo "未检测到完整 Android SDK，正在通过仓库 XML 获取命令行工具..."
    Assert-GlobalToolsRoot
    $info = Get-LatestAndroidCmdlineToolsUrl
    $zipPath = Join-Path $script:GlobalToolsRoot "android-cmdline-tools.zip"
    Download-File -Url $info.Url -Destination $zipPath -TimeoutSec $script:AndroidSdkDownloadTimeoutSec
    if (-not (Test-ZipArchiveIntegrity -Path $zipPath)) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        throw "Install-PortableAndroidSdk: cmdline-tools 压缩包校验失败（文件被截断或被替换为错误页面），请重试。"
    }

    $sdkRoot = $globalSdkRoot
    $cmdlineRoot = Join-Path $sdkRoot "cmdline-tools"
    $latestDir = Join-Path $cmdlineRoot "latest"

    if (Test-Path -LiteralPath $cmdlineRoot) {
        Remove-Item -LiteralPath $cmdlineRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $latestDir -Force | Out-Null

    $extractTmp = Join-Path $script:GlobalToolsRoot "android-cmdline-tmp"
    if (Test-Path -LiteralPath $extractTmp) {
        Remove-Item -LiteralPath $extractTmp -Recurse -Force
    }
    Expand-ArchiveRobust -Path $zipPath -DestinationPath $extractTmp -Force

    $inner = Get-ChildItem -LiteralPath $extractTmp -Directory | Select-Object -First 1
    if (-not $inner -or -not (Test-Path -LiteralPath (Join-Path $inner.FullName "bin"))) {
        throw "Install-PortableAndroidSdk: 解压后未找到 sdkmanager。"
    }

    Get-ChildItem -LiteralPath $inner.FullName -Force |
        Move-Item -Destination $latestDir -Force -ErrorAction Stop
    Remove-Item -LiteralPath $extractTmp -Recurse -Force -ErrorAction SilentlyContinue

    Add-PortablePath -Directory "$latestDir\bin" -HomeVariable "ANDROID_HOME" -HomeValue $sdkRoot
    [System.Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", $sdkRoot, [System.EnvironmentVariableTarget]::Process)

    $sdkmanager = Join-Path $latestDir "bin\sdkmanager.bat"
    if (-not (Test-Path -LiteralPath $sdkmanager)) {
        throw "sdkmanager.bat 不存在：$sdkmanager"
    }

    if (-not $script:AndroidAcceptLicenses) {
        Write-BuildWarn "即将自动接受 Android SDK 许可证。请确认你已阅读并同意相关许可条款。"
        Write-BuildWarn "可在 config.json 中设置 android.acceptLicenses 为 true 以跳过此提示。"
        $confirm = Read-Host "是否继续接受所有许可证？[Y/n，默认为 Y]"
        if ($confirm -and ($confirm -notmatch '^(Y|y)$')) {
            throw "用户取消了许可证接受，Android SDK 安装中断。"
        }
    }

    Write-BuildInfo "正在自动接受 Android SDK 许可证..."
    $licenseInput = ("y`n" * 30).TrimEnd("`n")
    $licenseOutput = $licenseInput | & $sdkmanager --licenses --sdk_root=$sdkRoot 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-BuildError $licenseOutput
        throw "接受 Android SDK 许可证失败，退出码 $LASTEXITCODE。"
    }

    # 使用镜像源手动下载并安装核心组件，避免 Google 官方源下载超时或中断
    $repoXml = $info.RepositoryXml
    $platformVersion = $script:AndroidTargetApiLevel

    Write-BuildInfo "手动安装 SDK 组件（镜像源）：platform-tools、platforms;android-$platformVersion ..."
    Install-AndroidSdkPackage -RepoXml $repoXml -PackagePath "platform-tools" -DestinationDir (Join-Path $sdkRoot "platform-tools")
    Install-AndroidSdkPackage -RepoXml $repoXml -PackagePath "platforms;android-$platformVersion" -DestinationDir (Join-Path $sdkRoot "platforms\android-$platformVersion")

    $buildToolsVersion = Get-AndroidBuildToolsVersion -RepoXml $repoXml
    Write-BuildInfo "手动安装 build-tools;$buildToolsVersion ..."
    Install-AndroidSdkPackage -RepoXml $repoXml -PackagePath "build-tools;$buildToolsVersion" -DestinationDir (Join-Path $sdkRoot "build-tools\$buildToolsVersion")

    Add-PortablePath -Directory "$sdkRoot\platform-tools"
    Write-BuildInfo "Android SDK 已准备就绪：$sdkRoot"
    return $sdkRoot
}
