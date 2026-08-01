#Requires -Version 5.1
#=============================================================================
# 07-ProjectDetect.ps1 - 项目类型检测与路径初始化
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================

# =============================================================================
# 初始化与路径设置
# =============================================================================

function Select-ProjectType {
    <#
        脚本开始时询问项目类型：1 Flutter / 2 Expo / 3 RN CLI / 4 原生 Android / 0 自动检测（默认）。
        返回类型枚举字符串：Flutter / Expo / RN / Native / Auto。
    #>
    Write-Host ''
    Write-Host '====================================================' -ForegroundColor Cyan
    Write-Host '  请问您的项目类型为：' -ForegroundColor Yellow
    Write-Host '    [1] Flutter        - 含 pubspec.yaml（dependencies 内含 flutter sdk 约束）与 android 目录' -ForegroundColor Gray
    Write-Host '    [2] Expo           - package.json 依赖含 expo' -ForegroundColor Gray
    Write-Host '    [3] RN CLI         - package.json 依赖含 react-native（可混用 expo 模块）' -ForegroundColor Gray
    Write-Host '    [4] 原生 Android   - settings.gradle(.kts) + gradlew.bat，无 package.json/pubspec.yaml' -ForegroundColor Gray
    Write-Host '    [5] Cordova         - config.xml 或 package.json 含 cordova 依赖' -ForegroundColor Gray
    Write-Host '    [0] 自动检测（默认，直接回车）' -ForegroundColor Gray
    Write-Host '====================================================' -ForegroundColor Cyan

    while ($true) {
        $choice = Read-Host '请输入选项 [0-5，默认 0]'
        if ([string]::IsNullOrWhiteSpace($choice)) { return 'Auto' }
        switch ($choice.Trim()) {
            '1' { return 'Flutter' }
            '2' { return 'Expo' }
            '3' { return 'RN' }
            '4' { return 'Native' }
            '5' { return 'Cordova' }
            '0' { return 'Auto' }
            default { Write-BuildWarn '无效选项，请重新输入。' }
        }
    }
}

function Get-ProjectTypeFeatureHint {
    <#
        返回各项目类型的目录特征提示文案（用于目录选择框 Description 与控制台提示）。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Flutter', 'Expo', 'RN', 'Native', 'Cordova', 'Auto')]
        [string]$Type
    )
    switch ($Type) {
        'Flutter' { return '包含 pubspec.yaml（dependencies 内含 flutter 且 sdk: flutter 约束、environment 含 sdk/flutter 约束）与 android 目录的项目根目录' }
        'Expo'    { return '包含 package.json（dependencies/devDependencies 含 expo）的项目根目录' }
        'RN'      { return '包含 package.json（dependencies/devDependencies 含 react-native）的项目根目录' }
        'Native'  { return '包含 settings.gradle(.kts) 与 gradlew.bat，且无 package.json/pubspec.yaml 的原生 Android 工程目录' }
        'Cordova' { return '包含 config.xml 或 package.json（dependencies/devDependencies 含 cordova 相关依赖）的项目根目录' }
        default   { return '包含 package.json、pubspec.yaml、config.xml 或 android 文件夹的项目根目录' }
    }
}

function Get-PackageDependencyNames {
    <#
        读取指定目录 package.json 的 dependencies + devDependencies 名称列表。
        文件不存在或解析失败时返回空数组。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Directory
    )
    $packageJsonPath = Join-Path $Directory 'package.json'
    if (-not (Test-Path -LiteralPath $packageJsonPath)) { return @() }

    try {
        $json = Get-Content -LiteralPath $packageJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $deps = @()
        if ($json.dependencies -and $json.dependencies.PSObject) {
            $deps += $json.dependencies.PSObject.Properties | ForEach-Object { $_.Name }
        }
        if ($json.devDependencies -and $json.devDependencies.PSObject) {
            $deps += $json.devDependencies.PSObject.Properties | ForEach-Object { $_.Name }
        }
        return $deps
    }
    catch {
        Write-BuildWarn "读取 package.json 失败：$($_.Exception.Message)"
        return @()
    }
}

function Test-PubspecFlutterConstraints {
    <#
        用缩进感知解析器校验 pubspec.yaml 内容（不引入 YAML 库）：
        1. dependencies.flutter 为 map 且其下 sdk 值 == 'flutter'；
        2. environment 段含 sdk 或 flutter 键（宽松或）。
        兼容任意缩进、段头行尾注释、段内注释与引号标量。
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $doc = ConvertFrom-YamlLite -Content $Content

    $dependencyOk = $false
    if ($doc.Contains('dependencies')) {
        $dependencies = $doc['dependencies']
        if ($dependencies -is [System.Collections.IDictionary] -and $dependencies.Contains('flutter')) {
            $flutter = $dependencies['flutter']
            if ($flutter -is [System.Collections.IDictionary] -and $flutter.Contains('sdk')) {
                $sdk = $flutter['sdk']
                if ($null -ne $sdk -and [string]$sdk -eq 'flutter') {
                    $dependencyOk = $true
                }
            }
        }
    }

    $environmentOk = $false
    if ($doc.Contains('environment')) {
        $environment = $doc['environment']
        if ($environment -is [System.Collections.IDictionary] -and
            ($environment.Contains('sdk') -or $environment.Contains('flutter'))) {
            $environmentOk = $true
        }
    }

    return @{ DependencyOk = $dependencyOk; EnvironmentOk = $environmentOk }
}

function Test-FlutterProjectFeatures {
    <#
        校验单个候选根目录的 Flutter 项目特征，返回缺失特征描述数组（空数组表示通过）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )
    $missing = @()
    $pubspecPath = Join-Path $Root 'pubspec.yaml'
    if (-not (Test-Path -LiteralPath $pubspecPath)) {
        $missing += 'pubspec.yaml 文件'
    }
    else {
        $content = ''
        try {
            $content = Get-Content -LiteralPath $pubspecPath -Raw -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-BuildWarn "读取 pubspec.yaml 失败：$($_.Exception.Message)"
        }
        if ($null -eq $content) { $content = '' }
        $check = Test-PubspecFlutterConstraints -Content $content
        if (-not $check.DependencyOk) { $missing += 'pubspec.yaml dependencies 段中的 flutter（sdk: flutter）约束' }
        if (-not $check.EnvironmentOk) { $missing += 'pubspec.yaml environment 段中的 sdk/flutter 约束' }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'android'))) {
        $missing += 'android 目录'
    }
    # 直接枚举返回：调用方以 @(...) 捕获，空数组 => 0 个元素
    return $missing
}

function Test-ProjectTypeFeatures {
    <#
        按项目类型校验目录特征。
        返回 @{ Pass=[bool]; Missing=[string[]]; ResolvedType=[string] }。
        Type=Auto 时按 Flutter → Expo → RN → Native 顺序判定并回填 ResolvedType（恒 Pass）。
        源码根候选：项目根本身或 mobile 子目录（与 mobileSubPath 约定的 monorepo 布局一致）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Flutter', 'Expo', 'RN', 'Native', 'Cordova', 'Auto')]
        [string]$Type
    )

    # 源码根候选：项目根本身；monorepo 时加上 mobileSubPath（未配置时回退约定目录 mobile）
    $roots = @($Path)
    if (-not [string]::IsNullOrWhiteSpace($script:MobileSubPath)) {
        $subDir = Join-Path $Path $script:MobileSubPath
        if (Test-Path -LiteralPath $subDir) { $roots += $subDir }
    }
    else {
        $mobileDir = Join-Path $Path 'mobile'
        if (Test-Path -LiteralPath $mobileDir) { $roots += $mobileDir }
    }

    # 收集各候选根的 package.json 依赖（Expo/RN/Cordova 判定；RN 不排斥 expo，混用项目两种类型均放行）
    $allDeps = @()
    $hasPackageJson = $false
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath (Join-Path $r 'package.json')) { $hasPackageJson = $true }
        $allDeps += @(Get-PackageDependencyNames -Directory $r)
    }
    $hasExpo = ($allDeps -contains 'expo')
    $hasReactNative = ($allDeps -contains 'react-native')
    $hasCordovaDep = ($allDeps | Where-Object { $_ -match '^cordova(?!-plugin)' }) -ne $null
    $hasConfigXml = $false
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath (Join-Path $r 'config.xml')) { $hasConfigXml = $true }
    }

    # Flutter 特征：任一候选根完整满足即通过；缺失项取项目根的检测结果用于提示
    $flutterOk = $false
    $flutterMissingAtRoot = @()
    foreach ($r in $roots) {
        $m = @(Test-FlutterProjectFeatures -Root $r)
        if ($r -eq $Path) { $flutterMissingAtRoot = $m }
        if ($m.Count -eq 0) { $flutterOk = $true }
    }
    $hasPubspec = $false
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath (Join-Path $r 'pubspec.yaml')) { $hasPubspec = $true }
    }

    $hasSettingsGradle = (Test-Path -LiteralPath (Join-Path $Path 'settings.gradle')) -or
                         (Test-Path -LiteralPath (Join-Path $Path 'settings.gradle.kts'))
    $hasGradlew = Test-Path -LiteralPath (Join-Path $Path 'gradlew.bat')

    $result = @{ Pass = $false; Missing = @(); ResolvedType = $Type }

    switch ($Type) {
        'Flutter' {
            if ($flutterOk) { $result.Pass = $true }
            else { $result.Missing = $flutterMissingAtRoot }
        }
        'Expo' {
            if ($hasExpo) { $result.Pass = $true }
            elseif ($hasPackageJson) { $result.Missing = @('package.json 中的 expo 依赖') }
            else { $result.Missing = @('package.json 文件（dependencies/devDependencies 含 expo）') }
        }
        'RN' {
            if ($hasReactNative) { $result.Pass = $true }
            elseif ($hasPackageJson) { $result.Missing = @('package.json 中的 react-native 依赖') }
            else { $result.Missing = @('package.json 文件（dependencies/devDependencies 含 react-native）') }
        }
        'Native' {
            $missing = @()
            if (-not $hasSettingsGradle) { $missing += 'settings.gradle(.kts) 文件' }
            if (-not $hasGradlew) { $missing += 'gradlew.bat 文件' }
            if ($hasPackageJson) { $missing += '不应存在的 package.json（检测到 JS 依赖，疑似 RN/Expo 项目）' }
            if ($hasPubspec) { $missing += '不应存在的 pubspec.yaml（疑似 Flutter 项目）' }
            if ($missing.Count -eq 0) { $result.Pass = $true } else { $result.Missing = $missing }
        }
        'Cordova' {
            if ($hasConfigXml) { $result.Pass = $true }
            elseif ($hasCordovaDep) { $result.Pass = $true }
            elseif ($hasPackageJson) { $result.Missing = @('config.xml 文件（或 package.json 中的 cordova / cordova-android 依赖）') }
            else { $result.Missing = @('config.xml 文件或 package.json') }
        }
        'Auto' {
            $result.Pass = $true
            if ($flutterOk -or $hasPubspec) {
                # pubspec 存在即按 Flutter 处理（特征不完整的 Flutter 项目由构建阶段兜底提示）
                $result.ResolvedType = 'Flutter'
            }
            elseif ($hasConfigXml -or $hasCordovaDep) {
                # config.xml 或 cordova 依赖优先于 Expo/RN
                $result.ResolvedType = 'Cordova'
            }
            elseif ($hasExpo) {
                $result.ResolvedType = 'Expo'
                if ($hasReactNative) { Write-BuildInfo '检测到 expo + react-native 混用项目，按 Expo 类型处理。' }
            }
            elseif ($hasReactNative) {
                $result.ResolvedType = 'RN'
            }
            elseif ($hasSettingsGradle -and $hasGradlew) {
                $result.ResolvedType = 'Native'
            }
            else {
                # 未识别：保持 Auto，交由现有通用目录逻辑处理
                $result.ResolvedType = 'Auto'
            }
        }
    }
    return $result
}

function Get-ProjectRootDirectory {
    <#
        检测脚本所在目录是否包含项目根目录特征（package.json 或 android 文件夹）。
        若检测不到，则弹出 Windows 文件夹选择框让用户选择项目根目录。
        指定 -ProjectType（非 Auto）时按所选类型做特征校验，
        不匹配时弹窗列出缺失特征并循环重新选择。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot,

        [Parameter()]
        [ValidateSet('Flutter', 'Expo', 'RN', 'Native', 'Cordova', 'Auto')]
        [string]$ProjectType = 'Auto'
    )

    # 辅助判断函数：给定目录是否包含项目根目录特征（通用检测，Auto 模式沿用）
    $isProjectRoot = {
        param([string]$Path)
        return (Test-Path -LiteralPath (Join-Path $Path "package.json")) -or
               (Test-Path -LiteralPath (Join-Path $Path "android")) -or
               (Test-Path -LiteralPath (Join-Path $Path "mobile\package.json")) -or
               (Test-Path -LiteralPath (Join-Path $Path "mobile\android")) -or
               (Test-Path -LiteralPath (Join-Path $Path "pubspec.yaml")) -or
               (Test-Path -LiteralPath (Join-Path $Path "mobile\pubspec.yaml")) -or
               (Test-Path -LiteralPath (Join-Path $Path "settings.gradle")) -or
               (Test-Path -LiteralPath (Join-Path $Path "settings.gradle.kts")) -or
               (Test-Path -LiteralPath (Join-Path $Path "config.xml"))
    }

    # 按所选类型校验目录特征
    $testDirectory = {
        param([string]$Path)
        if ($ProjectType -eq 'Auto') {
            return @{ Pass = (& $isProjectRoot -Path $Path); Missing = @() }
        }
        $r = Test-ProjectTypeFeatures -Path $Path -Type $ProjectType
        return @{ Pass = $r.Pass; Missing = @($r.Missing) }
    }

    $typeHint = Get-ProjectTypeFeatureHint -Type $ProjectType
    if ($ProjectType -ne 'Auto') {
        Write-BuildInfo "您选择了 $ProjectType 项目，请在接下来的目录选择中选择$typeHint。"
    }

    $candidate = $ScriptRoot
    if (& $isProjectRoot -Path $candidate) {
        if ($ProjectType -eq 'Auto') {
            Write-BuildInfo "已检测到项目根目录，直接使用：$candidate"
            return $candidate
        }
        $check = & $testDirectory -Path $candidate
        if ($check.Pass) {
            Write-BuildInfo "已检测到项目根目录，直接使用：$candidate"
            return $candidate
        }
        Write-BuildWarn "当前目录特征与您选择的 $ProjectType 类型不匹配（缺少：$($check.Missing -join '；')），请手动选择正确的项目目录。"
    }
    else {
        if ($ProjectType -eq 'Auto') {
            Write-BuildWarn "当前目录未找到 package.json 或 android 文件夹，需要手动选择项目根目录。"
        }
        else {
            Write-BuildWarn "当前目录不符合 $ProjectType 项目特征，需要手动选择项目根目录。"
        }
    }

    Add-Type -AssemblyName System.Windows.Forms | Out-Null

    while ($true) {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($ProjectType -eq 'Auto') {
            $dialog.Description = "请选择项目根目录（包含 package.json 的文件夹）"
        }
        else {
            $dialog.Description = "您选择了 $ProjectType 项目，请选择$typeHint"
        }
        $dialog.ShowNewFolderButton = $false

        Write-BuildInfo "正在弹出项目目录选择框..."
        $result = $dialog.ShowDialog()

        if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
            throw "用户取消了项目目录选择，脚本已退出。"
        }

        $selected = $dialog.SelectedPath
        $check = & $testDirectory -Path $selected
        if ($check.Pass) {
            Write-BuildInfo "已确认项目根目录：$selected"
            return $selected
        }

        if ($ProjectType -eq 'Auto') {
            Write-BuildWarn "所选目录未包含 package.json 或 android 文件夹，请重新选择。"
            [System.Windows.Forms.MessageBox]::Show(
                "所选目录未识别为项目根目录。请重新选择包含 package.json 或 android 文件夹的目录。",
                "目录无效",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
        else {
            $missingText = ($check.Missing | ForEach-Object { "  - $_" }) -join "`n"
            Write-BuildWarn "所选目录与 $ProjectType 项目特征不匹配，请重新选择。"
            [System.Windows.Forms.MessageBox]::Show(
                "您选择了 $ProjectType 项目，但所选目录缺少以下特征：`n$missingText`n`n请重新选择$typeHint。",
                "目录与项目类型不匹配",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    }
}

function Initialize-BuildConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,

        [Parameter()]
        [ValidateSet('Flutter', 'Expo', 'RN', 'Native', 'Cordova', 'Auto')]
        [string]$ProjectType = 'Auto'
    )
    $script:ProjectRoot = Resolve-Path $ProjectRoot | Select-Object -ExpandProperty Path
    $script:ProjectName = Split-Path -Leaf $script:ProjectRoot
    if ([string]::IsNullOrWhiteSpace($script:MobileSubPath)) {
        $script:MobileRoot = $script:ProjectRoot
    }
    else {
        $script:MobileRoot = Join-Path $script:ProjectRoot $script:MobileSubPath
    }

    # 解析实际项目类型：Auto 时按目录特征判定；手动类型已在上游校验通过，直接采用
    $script:ProjectType = $ProjectType
    $typeResult = Test-ProjectTypeFeatures -Path $script:ProjectRoot -Type $ProjectType
    $script:DetectedProjectType = $typeResult.ResolvedType
    if ([string]::IsNullOrWhiteSpace($script:DetectedProjectType)) { $script:DetectedProjectType = $ProjectType }
    $script:IsFlutterProject = ($script:DetectedProjectType -eq 'Flutter')
    $script:IsCordovaProject = ($script:DetectedProjectType -eq 'Cordova')
    if ($ProjectType -eq 'Auto' -and $script:DetectedProjectType -ne 'Auto') {
        Write-BuildInfo "自动检测项目类型：$($script:DetectedProjectType)"
    }
    # Cordova 项目的 android 目录位于 platforms/android（由 cordova platform add 生成）
    if ($script:IsCordovaProject) {
        $script:AndroidDir  = Join-Path $script:MobileRoot "platforms\android"
    }
    else {
        $script:AndroidDir  = Join-Path $script:MobileRoot "android"
    }
    $script:IsNativeAndroidProject = $false
    if (-not (Test-Path -LiteralPath $script:AndroidDir)) {
        # 原生 Android Studio 项目：项目根目录即 Android 工程（settings.gradle + gradlew），
        # 没有 RN/Expo 的 android 子目录，此时 AndroidDir 直接指向项目根
        $hasSettingsGradle = (Test-Path -LiteralPath (Join-Path $script:MobileRoot 'settings.gradle')) -or
                             (Test-Path -LiteralPath (Join-Path $script:MobileRoot 'settings.gradle.kts'))
        $hasGradlew = Test-Path -LiteralPath (Join-Path $script:MobileRoot 'gradlew.bat')
        if ($hasSettingsGradle -and $hasGradlew) {
            $script:AndroidDir = $script:MobileRoot
            $script:IsNativeAndroidProject = $true
            Write-BuildInfo "检测到原生 Android 项目结构，Android 工程目录：$($script:AndroidDir)"
        }
    }
    $script:ReleaseDir  = Join-Path $script:MobileRoot "release"
    $script:SigningDir  = Join-Path $script:MobileRoot ".signing"
    $script:ToolsDir    = $script:GlobalToolsRoot
    $script:ProjectCacheDir = Join-Path $script:GlobalCacheRoot $script:ProjectName
    $script:GradleUserHome  = $script:GradleUserHomePattern -replace '\{project\}', (Get-ShortProjectId)

    # 强制使用 TLS 1.2+，Tls13 在旧版 .NET 上可能不存在，动态设置避免崩溃
    $protocols = [Net.SecurityProtocolType]::Tls12
    try {
        $protocols = $protocols -bor [Net.SecurityProtocolType]::Tls13
    }
    catch {
        Write-BuildWarn "当前系统不支持 TLS 1.3，仅启用 TLS 1.2。"
    }
    [Net.ServicePointManager]::SecurityProtocol = $protocols
}


# =============================================================================
# 核心构建流程
# =============================================================================

function Test-ExpoProject {
    <#
        检查项目是否为 Expo 项目（package.json 中包含 expo 依赖）。
    #>
    $deps = @(Get-PackageDependencyNames -Directory $script:MobileRoot)
    return ($deps -contains "expo")
}
