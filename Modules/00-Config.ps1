#Requires -Version 5.1
#=============================================================================
# 00-Config.ps1 - 配置加载与模块默认值
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================

# =============================================================================
# 配置区 - 默认配置；可通过 config.json 覆盖，未覆盖项使用下方默认值
# =============================================================================

function Read-BuildConfig {
    <#
    .SYNOPSIS
        读取 config.json 配置文件。
    .DESCRIPTION
        如果模块同级目录存在 config.json，则读取并返回解析后的对象；
        否则返回空对象，使用模块内默认值。
    #>
    [CmdletBinding()]
    param()
    $configPath = Join-Path $script:BuildHelperRoot 'config.json'
    if (-not (Test-Path $configPath)) { return [PSCustomObject]@{} }
    try {
        $raw = Get-Content $configPath -Raw -Encoding UTF8 -ErrorAction Stop
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        Write-BuildError "读取配置文件失败: $configPath。将使用默认配置。详情: $_"
        return [PSCustomObject]@{}
    }
}

function Initialize-ModuleSettings {
    <#
    .SYNOPSIS
        用 config.json 中的值覆盖模块默认配置。
    .DESCRIPTION
        加载 config.json 后，将其中的值合并到 $script: 作用域变量。
        缺失项保持模块默认值，保证向后兼容。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    function Get-ConfigValue {
        param([object]$Object, [string[]]$Path, [object]$Default)
        $current = $Object
        foreach ($segment in $Path) {
            if ($null -eq $current) { return $Default }
            $prop = $current.PSObject.Properties[$segment]
            if ($prop) { $current = $prop.Value }
            else { return $Default }
        }
        if ($null -eq $current) { return $Default }
        return $current
    }

    # 默认值以模块下方字面量初始化为准（单一来源，避免双份维护），此处仅用 config.json 覆盖当前值
    $script:UserAgent           = Get-ConfigValue $Config @('download','userAgent') $script:UserAgent
    $script:RequestTimeoutSec   = [int](Get-ConfigValue $Config @('download','requestTimeoutSec') $script:RequestTimeoutSec)
    $script:DownloadTimeoutSec  = [int](Get-ConfigValue $Config @('download','downloadTimeoutSec') $script:DownloadTimeoutSec)
    $script:MaxRetries          = [int](Get-ConfigValue $Config @('download','maxRetries') $script:MaxRetries)
    $script:ProxyPrefix         = Get-ConfigValue $Config @('download','proxyPrefix') $script:ProxyPrefix

    $script:TemurinBinaryUrl    = Get-ConfigValue $Config @('jdk','binaryUrl') $script:TemurinBinaryUrl
    $script:TemurinReleaseInfoUrl = Get-ConfigValue $Config @('jdk','releaseInfoUrl') $script:TemurinReleaseInfoUrl
    $script:TemurinGitHubRepo   = Get-ConfigValue $Config @('jdk','githubRepo') $script:TemurinGitHubRepo
    $script:TemurinGitHubReleaseApi = Get-ConfigValue $Config @('jdk','githubReleaseApi') $script:TemurinGitHubReleaseApi

    $script:JdkProxyPrefixes    = @(Get-ConfigValue $Config @('download','jdkProxyPrefixes') $script:JdkProxyPrefixes)

    $script:AndroidRepositoryXml = Get-ConfigValue $Config @('download','androidRepositoryXml') $script:AndroidRepositoryXml
    $script:AndroidUseMirror    = [bool](Get-ConfigValue $Config @('android','useMirror') $script:AndroidUseMirror)
    $script:AndroidMirrorBase   = Get-ConfigValue $Config @('android','mirrorBase') $script:AndroidMirrorBase
    $script:AndroidSdkDownloadTimeoutSec = [int](Get-ConfigValue $Config @('download','androidSdkDownloadTimeoutSec') $script:AndroidSdkDownloadTimeoutSec)

    $script:AndroidTargetApiLevel = [int](Get-ConfigValue $Config @('android','targetApiLevel') $script:AndroidTargetApiLevel)
    $script:AndroidAcceptLicenses = [bool](Get-ConfigValue $Config @('android','acceptLicenses') $script:AndroidAcceptLicenses)

    $script:NodeDistIndexUrl    = Get-ConfigValue $Config @('node','distIndexUrl') $script:NodeDistIndexUrl
    $script:NodeAssetSuffix      = Get-ConfigValue $Config @('node','assetSuffix') $script:NodeAssetSuffix

    $script:FlutterStorageBaseUrl = Get-ConfigValue $Config @('flutter','storageBaseUrl') $script:FlutterStorageBaseUrl
    $script:PubHostedUrl         = Get-ConfigValue $Config @('flutter','pubHostedUrl') $script:PubHostedUrl
    $script:MinGitDownloadUrl    = Get-ConfigValue $Config @('git','mingitUrl') $script:MinGitDownloadUrl
    $script:GitMirrorInsteadOf   = Get-ConfigValue $Config @('git','mirrorInsteadOf') $script:GitMirrorInsteadOf
    $script:GitMirrorCandidates  = @(Get-ConfigValue $Config @('git','mirrorCandidates') $script:GitMirrorCandidates)

    # 环境变量分流：BUILDHELPER_NO_PROXY=1 时清零所有代理前缀，全程直连下载（有梯子用户）
    if ($env:BUILDHELPER_NO_PROXY -eq '1') {
        $script:ProxyPrefix        = ''
        $script:JdkProxyPrefixes   = @('')
        $script:GitMirrorCandidates = @()
        Write-BuildInfo 'BUILDHELPER_NO_PROXY=1：已禁用所有下载代理与 git 镜像，全程直连。'
    }

    $script:RequiredJdkMajorVersion = [int](Get-ConfigValue $Config @('jdk','requiredMajorVersion') $script:RequiredJdkMajorVersion)
    $script:JdkAutoDetect          = [bool](Get-ConfigValue $Config @('jdk','autoDetect') $script:JdkAutoDetect)

    $script:SigningKeyAlias     = Get-ConfigValue $Config @('signing','keyAlias') $script:SigningKeyAlias
    $script:SigningDname        = Get-ConfigValue $Config @('signing','dname') $script:SigningDname

    $script:MobileSubPath       = Get-ConfigValue $Config @('paths','mobileSubPath') $script:MobileSubPath
    $script:GlobalToolsRoot     = Get-ConfigValue $Config @('paths','globalToolsRoot') $script:GlobalToolsRoot
    $script:GradleUserHomePattern = Get-ConfigValue $Config @('paths','gradleUserHome') $script:GradleUserHomePattern

    # Cordova 配置
    $script:CordovaCliVersion   = Get-ConfigValue $Config @('cordova','cliVersion') $script:CordovaCliVersion
    $script:CordovaNpmRegistry  = Get-ConfigValue $Config @('cordova','npmRegistry') $script:CordovaNpmRegistry
    $script:CordovaAndroidPlatformVersion = Get-ConfigValue $Config @('cordova','androidPlatformVersion') $script:CordovaAndroidPlatformVersion
    $script:CordovaBuildDebug   = [bool](Get-ConfigValue $Config @('cordova','buildDebug') $script:CordovaBuildDebug)
    $script:CordovaJdkMajorVersion = Get-ConfigValue $Config @('cordova','jdkMajorVersion') $script:CordovaJdkMajorVersion
    # Gradle 配置
    $script:GradleBootstrapVersion = Get-ConfigValue $Config @('gradle','bootstrapVersion') $script:GradleBootstrapVersion
    # requirements 节
    $script:RequirementsInstallSdk = [bool](Get-ConfigValue $Config @('requirements','installSdk') $script:RequirementsInstallSdk)
    $script:RequirementsInstallNdk = Get-ConfigValue $Config @('requirements','installNdk') $script:RequirementsInstallNdk
}

$script:UserAgent           = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) BuildHelper/1.0'
$script:RequestTimeoutSec   = 10
$script:DownloadTimeoutSec  = 1800
$script:MaxRetries          = 3
$script:ProxyPrefix         = 'https://gh-proxy.com/'

# JDK 源：Adoptium Temurin 官方 API（无需 GitHub API Token，无 api.github.com 速率限制）
$script:TemurinBinaryUrl    = 'https://api.adoptium.net/v3/binary/latest/{0}/ga/windows/x64/jdk/hotspot/normal/eclipse'
$script:TemurinReleaseInfoUrl = 'https://api.adoptium.net/v3/assets/latest/{0}/ga?vendor=eclipse&os=windows&arch=x64&image_type=jdk'

# JDK 候选源代理镜像（用于 API 与 GitHub 访问；空字符串表示直连）
$script:JdkProxyPrefixes = @(
    "",
    "https://gh-proxy.com/"
)

# GitHub Releases 兜底源：adoptium/temurin{0}-binaries
$script:TemurinGitHubRepo   = 'adoptium/temurin{0}-binaries'
$script:TemurinGitHubReleaseApi = 'https://api.github.com/repos/{0}/releases?per_page=10'

# Android SDK 源：Google 官方仓库 XML（避免硬编码 build 号）
$script:AndroidRepositoryXml = 'https://dl.google.com/android/repository/repository2-1.xml'

# Android SDK 镜像源（默认腾讯云，可替换为其他可用镜像）
$script:AndroidUseMirror = $true
$script:AndroidMirrorBase = 'https://mirrors.cloud.tencent.com/AndroidSDK'
$script:AndroidSdkDownloadTimeoutSec = 180

# Android SDK 目标 API 级别（Android 34 稳定且兼容性好）
$script:AndroidTargetApiLevel = 34
$script:AndroidAcceptLicenses = $false

# Node.js 源：官方 dist 索引（无需 GitHub API Token）
$script:NodeDistIndexUrl    = 'https://nodejs.org/dist/index.json'
$script:NodeAssetSuffix      = 'win-x64.zip'

# Flutter 源：发布元数据与 SDK 归档（默认国内镜像，回退官方源时自动替换 host）
$script:FlutterStorageBaseUrl = 'https://storage.flutter-io.cn'
$script:FlutterOfficialStorageBaseUrl = 'https://storage.googleapis.com'
# Dart pub 依赖镜像（flutter pub get 使用）
$script:PubHostedUrl        = 'https://pub.flutter-io.cn'

# MinGit（Git for Windows 官方最小化便携版，纯 zip 解压即用）：
# Flutter 工具链运行时硬性依赖 git（flutter.bat 启动时 WHERE git 检查），
# 系统 PATH 无 git 时自动下载本便携版，无需用户预装
$script:MinGitDownloadUrl   = 'https://github.com/git-for-windows/git/releases/download/v2.46.0.windows.1/MinGit-2.46.0-64-bit.zip'

# GitHub git 镜像（url.insteadOf 重写目标）：pubspec 中的 git 依赖默认指向
# https://github.com/，国内 clone 困难；通过 GIT_CONFIG_* 会话级环境变量注入
# url.insteadOf 前缀重写（不修改用户 .gitconfig），对 flutter pub get 透明生效。
# 显式配置 GitMirrorInsteadOf 时直接使用；为空时按 GitMirrorCandidates 顺序
# 探测 git 协议可用性（ls-remote 小仓库）并自动选择第一个可达镜像。
# 注意 ls-remote 探测只验证可达性、验证不了大流量吞吐：gitclone.com 对未缓存
# 仓库的 clone --mirror 全量传输会长时间挂起（实测 media-kit 81MB 卡死无响应），
# 而 gh-proxy 实测 1MB/s 稳定完成全量克隆，故 gh-proxy 排在候选首位。
$script:GitMirrorInsteadOf  = ''
$script:GitMirrorCandidates = @(
    'https://gh-proxy.com/https://github.com/',
    'https://gitclone.com/github.com/'
)

# 目标 JDK 主版本。RN/Expo 的 Gradle 构建固定请求 Java 17 toolchain
# （react-native-gradle-plugin 的 JdkConfigurator / gradle-daemon-jvm.properties）。
# 若提供的 JDK 主版本不匹配，foojay-resolver 会从 api.foojay.io 自动下载 JDK，
# 国内网络下会在 Evaluating settings 阶段卡死。
$script:RequiredJdkMajorVersion = 17
$script:JdkAutoDetect          = $true

# 应用签名信息：留空 = 生成新密钥时按当前项目自动派生（包名末段→alias、应用名→dname），
# 避免跨项目共用身份；显式填写可强制指定（单项目固定签名场景）。
# 已有 .signing 材料的项目始终直接复用，不受此处影响。
$script:SigningKeyAlias     = ''
$script:SigningDname        = ''

# 项目路径（由 Initialize-BuildConfiguration 填充）
# 如果 mobile 代码不在仓库根目录，请修改 MobileSubPath，例如 "mobile"
$script:MobileSubPath       = ''
$script:ProjectRoot         = $script:BuildHelperRoot
$script:ProjectName         = Split-Path -Leaf $script:BuildHelperRoot
$script:MobileRoot          = $script:BuildHelperRoot
$script:AndroidDir          = Join-Path $script:BuildHelperRoot 'android'
$script:ReleaseDir          = Join-Path $script:BuildHelperRoot 'release'
$script:SigningDir          = Join-Path $script:BuildHelperRoot '.signing'

# 项目类型：ProjectType 为用户选择（Auto 表示自动检测），DetectedProjectType 为按目录特征解析后的实际类型
$script:ProjectType         = 'Auto'
$script:DetectedProjectType = 'Auto'
$script:IsFlutterProject    = $false
$script:IsCordovaProject   = $false

# Cordova 配置默认值
$script:CordovaCliVersion   = 'latest'
$script:CordovaNpmRegistry  = 'https://registry.npmmirror.com'
$script:CordovaAndroidPlatformVersion = ''
$script:CordovaBuildDebug   = $true
# JDK 主版本：'auto' 按 cordova-android 版本自动选择（>=12→17、10~11→11、<=9→8）；
# 也可填 8 / 11 / 17 强制指定（老项目插件不兼容新版工具链时用 8）
$script:CordovaJdkMajorVersion = 'auto'

# Gradle 配置默认值
# 引导用 Gradle 版本（cordova-android ≥15 构建需系统 Gradle 生成 wrapper）：
# 留空 = 自动读取 cordova-android 的 GRADLE_VERSION；显式填写（如 "8.14.2"）可强制指定
$script:GradleBootstrapVersion = ''

# requirements 节
$script:RequirementsInstallSdk = $true
$script:RequirementsInstallNdk = 'ask'   # 'ask' | 'always' | 'never'

# 构建日志落盘状态（Start-ReleaseBuild 构建前初始化，finally 释放）
$script:BuildLogPath        = $null
$script:BuildLogWriter      = $null

# 全局共享工具目录（短路径，避免源码污染与 260 字符长路径问题）
# 默认 C:\APKTools，可手动改为任意短路径
$script:GlobalToolsRoot     = 'C:\APKTools'

# Gradle 用户主目录路径模式：{project} 会被替换为项目短标识。
# 刻意使用极短前缀：RN 的 C++ 构建会引用 transforms 缓存内深层 prefab 头文件，
# GRADLE_USER_HOME 前缀过长时整条路径容易突破 Win32 260 字符上限（ninja 直接报 Stat 失败）
$script:GradleUserHomePattern = 'C:\APKTools\g\{project}'
$script:GlobalCacheRoot     = Join-Path $script:GlobalToolsRoot '.cache'
$script:ProjectCacheDir     = Join-Path $script:GlobalCacheRoot $script:ProjectName

# 兼容旧代码的别名（不再使用源码内 .tools）
$script:ToolsDir            = $script:GlobalToolsRoot

# 加载 config.json 并覆盖默认值；依赖 GlobalToolsRoot 的派生路径在覆盖后重新计算
$script:BuildConfig = Read-BuildConfig
Initialize-ModuleSettings -Config $script:BuildConfig
$script:GlobalCacheRoot     = Join-Path $script:GlobalToolsRoot '.cache'
$script:ProjectCacheDir     = Join-Path $script:GlobalCacheRoot $script:ProjectName
$script:ToolsDir            = $script:GlobalToolsRoot
