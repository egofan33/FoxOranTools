#Requires -Version 5.1
#=============================================================================
# 12-Signing.ps1 - 签名材料与 APK 输出
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================


# =============================================================================
# 签名材料生成
# =============================================================================

function Resolve-SigningIdentity {
    <#
        确定签名身份（alias 与 dname）：
        config signing.keyAlias / signing.dname 显式配置时优先（单项目固定签名场景）；
        留空则按当前项目自动派生，避免跨项目共用同一身份：
          包名候选链：Cordova config.xml widget id → app\build.gradle(.kts) applicationId
                     → package.json name → pubspec.yaml name → 项目目录名
          alias：包名末段（跳过 app/android 等通用段向前补齐），清洗为小写字母数字连字符
          dname：CN=<应用名>, OU=Android, O=<应用名>, C=CN（应用名沿用包名候选链）
        仅影响"生成新密钥"的时刻；已有 .signing 材料的项目直接复用、不受影响。
    #>
    [CmdletBinding()]
    param()

    $alias = "$script:SigningKeyAlias".Trim()
    $dname = "$script:SigningDname".Trim()
    if ($alias -and $dname) {
        return @{ Alias = $alias; Dname = $dname }
    }

    $packageId = $null
    $appName   = $null

    # 1. Cordova：config.xml 的 widget id 与 <name>
    $configXml = Join-Path $script:MobileRoot 'config.xml'
    if (Test-Path -LiteralPath $configXml) {
        try {
            $xmlText = Get-Content -LiteralPath $configXml -Raw -Encoding UTF8 -ErrorAction Stop
            if ($xmlText -match '<widget\s+[^>]*id\s*=\s*"([^"]+)"') { $packageId = $Matches[1] }
            if ($xmlText -match '<name>\s*([^<]+?)\s*</name>') { $appName = $Matches[1] }
        }
        catch { }
    }

    # 2. Android 工程：app\build.gradle(.kts) 的 applicationId
    if (-not $packageId) {
        foreach ($gradleFile in @(
            (Join-Path $script:AndroidDir 'app\build.gradle'),
            (Join-Path $script:AndroidDir 'app\build.gradle.kts'))) {
            if (-not (Test-Path -LiteralPath $gradleFile)) { continue }
            try {
                $g = Get-Content -LiteralPath $gradleFile -Raw -Encoding UTF8 -ErrorAction Stop
                if ($g -match 'applicationId\s*[= ]\s*["'']([^"'']+)["'']') { $packageId = $Matches[1]; break }
            }
            catch { }
        }
    }

    # 3. package.json 的 name（RN/Expo，亦作应用名候选）
    $pkgJson = Join-Path $script:MobileRoot 'package.json'
    if (Test-Path -LiteralPath $pkgJson) {
        try {
            $pkg = Get-Content -LiteralPath $pkgJson -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if (-not $packageId -and "$($pkg.name)") { $packageId = "$($pkg.name)" }
            if (-not $appName -and "$($pkg.name)") { $appName = "$($pkg.name)" }
        }
        catch { }
    }

    # 4. pubspec.yaml 的 name（Flutter）
    if (-not $packageId -or -not $appName) {
        $pubspec = Join-Path $script:MobileRoot 'pubspec.yaml'
        if (Test-Path -LiteralPath $pubspec) {
            try {
                $p = Get-Content -LiteralPath $pubspec -Raw -Encoding UTF8 -ErrorAction Stop
                if ($p -match '(?m)^name:\s*([^\s#]+)') {
                    if (-not $packageId) { $packageId = $Matches[1] }
                    if (-not $appName) { $appName = $Matches[1] }
                }
            }
            catch { }
        }
    }

    # 5. 兜底：项目目录名
    if (-not $packageId) { $packageId = $script:ProjectName }
    if (-not $appName)   { $appName   = $script:ProjectName }

    if (-not $alias) {
        $generic = @('app', 'android', 'client', 'mobile', 'main', 'debug', 'release')
        $segments = @($packageId -split '[\.\-/]' | Where-Object { $_ })
        for ($i = $segments.Count - 1; $i -ge 0; $i--) {
            $seg = ($segments[$i] -replace '[^a-zA-Z0-9]', '').ToLower()
            if (-not $seg) { continue }
            $alias = if ($alias) { "$seg-$alias" } else { $seg }
            if ($seg.Length -ge 3 -and -not ($generic -contains $seg)) { break }
        }
        if (-not $alias) { $alias = 'app' }
    }

    if (-not $dname) {
        $cn = ($appName -replace '[",=]', '').Trim()
        if (-not $cn) { $cn = $alias }
        $dname = "CN=$cn, OU=Android, O=$cn, C=CN"
    }

    Write-BuildInfo "签名身份（按项目自动派生）：alias=$alias；dname=$dname"
    return @{ Alias = $alias; Dname = $dname }
}

function New-SigningMaterial {
    param(
        [Parameter(Mandatory = $true)][string]$SigningDir,
        [Parameter(Mandatory = $true)][string]$Keytool
    )

    $identity = Resolve-SigningIdentity
    $keystorePath = Join-Path $SigningDir "$($identity.Alias)-upload.jks"
    if (-not (Test-Path -LiteralPath $keystorePath)) {
        # 按当前 alias 命名的 keystore 不存在时，沿用目录中已有的任意 *-upload.jks
        #（兼容历史 bilitogether-upload.jks 及用户手动放入的自有密钥）
        $existingKeystores = @(Get-ChildItem -LiteralPath $SigningDir -Filter '*-upload.jks' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        if ($existingKeystores.Count -gt 0) {
            Write-BuildInfo "沿用现有 keystore：$($existingKeystores[0].Name)"
            $keystorePath = $existingKeystores[0].FullName
        }
    }
    $passwordPath = Join-Path $SigningDir "signing-password.txt"
    $aliasPath    = Join-Path $SigningDir "signing-alias.txt"

    if ((Test-Path -LiteralPath $keystorePath) -xor (Test-Path -LiteralPath $passwordPath)) {
        throw "签名材料不完整：$SigningDir。请同时恢复 keystore 与密码文件。"
    }

    if (-not (Test-Path -LiteralPath $keystorePath)) {
        New-Item -ItemType Directory -Path $SigningDir -Force | Out-Null

        # 允许用户通过环境变量指定签名密码；否则生成随机强密码
        $providedByUser = -not [string]::IsNullOrWhiteSpace($env:BILITOGETHER_SIGNING_PASSWORD)
        $password = if ($providedByUser) {
            $env:BILITOGETHER_SIGNING_PASSWORD
        }
        else {
            $randomBytes = New-Object byte[] 32
            # RandomNumberGenerator.Fill 静态方法仅 .NET 5+（PS7+）可用；
            # Create()+GetBytes() 实例写法兼容 .NET Framework 4.x（Windows PowerShell 5.1）
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            try {
                $rng.GetBytes($randomBytes)
            }
            finally {
                $rng.Dispose()
            }
            [Convert]::ToBase64String($randomBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        }

        $env:BILITOGETHER_SIGNING_PASSWORD = $password
        try {
            & $Keytool `
                -genkeypair `
                -keystore $keystorePath `
                -storetype PKCS12 `
                -alias $identity.Alias `
                -keyalg RSA `
                -keysize 4096 `
                -validity 10000 `
                -dname $identity.Dname `
                '-storepass:env' BILITOGETHER_SIGNING_PASSWORD `
                '-keypass:env' BILITOGETHER_SIGNING_PASSWORD

            if ($LASTEXITCODE -ne 0) {
                throw "keytool 生成密钥失败，退出码 $LASTEXITCODE。"
            }
        }
        finally {
            # 仅当密码由脚本生成时才从环境变量中移除，用户提供的可保留
            if (-not $providedByUser) {
                Remove-Item Env:BILITOGETHER_SIGNING_PASSWORD -ErrorAction SilentlyContinue
            }
        }

        # 无 BOM UTF8 写入：避免其他工具读取密码文件时把 BOM 当作密码内容
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($passwordPath, $password, $utf8NoBom)
        [System.IO.File]::WriteAllText($aliasPath, $identity.Alias, $utf8NoBom)

        Write-BuildWarn "已生成新的签名密钥，请务必备份目录：$SigningDir"
    }

    # 签名材料含明文密码，确保不会被 git 提交（幂等，每次构建都检查）
    $gitignorePath = Join-Path $script:MobileRoot '.gitignore'
    $ignoreEntry = '.signing/'
    if (Test-Path -LiteralPath $gitignorePath) {
        $ignoreLines = @(Get-Content -LiteralPath $gitignorePath -Encoding UTF8 -ErrorAction SilentlyContinue)
        $alreadyIgnored = $ignoreLines | Where-Object { $_.Trim() -in @('.signing', '.signing/') }
        if (-not $alreadyIgnored) {
            Add-Content -LiteralPath $gitignorePath -Value $ignoreEntry -Encoding UTF8
            Write-BuildInfo "已向 .gitignore 追加 $ignoreEntry（防止签名材料被提交）。"
        }
    }
    else {
        Set-Content -LiteralPath $gitignorePath -Value $ignoreEntry -Encoding UTF8
        Write-BuildInfo "已创建 .gitignore 并加入 $ignoreEntry（防止签名材料被提交）。"
    }

    return [pscustomobject]@{
        Keystore = $keystorePath
        Password = $passwordPath
        Alias    = if (Test-Path -LiteralPath $aliasPath) { (Get-Content -LiteralPath $aliasPath -Raw -Encoding UTF8 -ErrorAction Stop).Trim() } else { $identity.Alias }
    }
}

# =============================================================================
# APK 输出：重名自动加时间戳 + 复制到 release 目录
# =============================================================================

function Copy-ApkToRelease {
    param(
        [Parameter(Mandatory = $true)][string]$SourceApk,
        # 输出文件名（默认 app-release.apk）；调试包传 app-debug.apk 等，重名时自动加时间戳后缀
        [string]$BaseName = 'app-release.apk'
    )

    New-Item -ItemType Directory -Path $script:ReleaseDir -Force | Out-Null

    $targetPath = Join-Path $script:ReleaseDir $BaseName

    if (Test-Path -LiteralPath $targetPath) {
        $ts = Get-Date -Format "yyyyMMdd-HHmmss"
        $nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($BaseName)
        $ext = [System.IO.Path]::GetExtension($BaseName)
        $BaseName = "$nameNoExt-$ts$ext"
        $targetPath = Join-Path $script:ReleaseDir $BaseName
        Write-BuildWarn "release 目录已存在同名 APK，将使用时间戳后缀：$BaseName"
    }

    Write-BuildInfo "将 APK 复制到 release 目录..."
    Copy-Item -LiteralPath $SourceApk -Destination $targetPath -Force -ErrorAction Stop

    return $targetPath
}

function Invoke-ApkSignAndPublish {
    <#
        对待签名 APK 执行完整签名发布流程：
        准备签名材料 → zipalign 对齐（可用时）→ apksigner 签名 → 校验 → 复制到 release 目录。
        返回最终 release 目录中的 APK 路径。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$UnsignedApkPath,
        [Parameter(Mandatory = $true)][string]$JavaHome,
        [Parameter(Mandatory = $true)][string]$SdkRoot,
        # 输出文件名（默认 app-release.apk），重名时 Copy-ApkToRelease 自动加时间戳后缀
        [string]$BaseName = 'app-release.apk'
    )

    # 签名材料
    $keytool = Join-Path $JavaHome "bin\keytool.exe"
    $signing = New-SigningMaterial -SigningDir $script:SigningDir -Keytool $keytool

    $buildToolsDirs = Get-ChildItem -LiteralPath (Join-Path $SdkRoot "build-tools") -Directory -ErrorAction SilentlyContinue |
        Sort-Object { try { [version]$_.Name } catch { [version]"0.0" } } -Descending
    if (-not $buildToolsDirs) {
        throw "未找到 Android SDK build-tools 目录。"
    }
    $apksigner = Join-Path $buildToolsDirs[0].FullName "apksigner.bat"
    if (-not (Test-Path -LiteralPath $apksigner)) {
        throw "未找到 apksigner：$apksigner"
    }

    $stagingDir = Join-Path $script:ProjectCacheDir "staging"
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $signedApkStaging = Join-Path $stagingDir "signed-$timestamp.apk"

    # zipalign：v2 签名方案要求先对齐再签名；zipalign 不可用时保持原有直接签名流程
    $zipalign = Join-Path $buildToolsDirs[0].FullName "zipalign.exe"
    $apkToSign = $UnsignedApkPath
    $alignedApk = Join-Path $stagingDir "aligned-$timestamp.apk"
    if (Test-Path -LiteralPath $zipalign) {
        Write-BuildInfo "正在执行 zipalign 对齐..."
        & $zipalign -p -f 4 $apkToSign $alignedApk
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $alignedApk)) {
            $apkToSign = $alignedApk
        }
        else {
            Write-BuildWarn "zipalign 失败（退出码 $LASTEXITCODE），将直接签名未对齐 APK。"
        }
    }
    else {
        Write-BuildWarn "未找到 zipalign.exe，跳过对齐步骤。"
    }

    $signingPassword = (Get-Content -LiteralPath $signing.Password -Raw -Encoding UTF8 -ErrorAction Stop).Trim()
    $env:BILITOGETHER_SIGNING_PASSWORD = $signingPassword
    try {
        Write-BuildInfo "正在签名 APK..."
        & $apksigner sign `
            --ks $signing.Keystore `
            --ks-key-alias $signing.Alias `
            --ks-pass "env:BILITOGETHER_SIGNING_PASSWORD" `
            --key-pass "env:BILITOGETHER_SIGNING_PASSWORD" `
            --out $signedApkStaging `
            $apkToSign

        if ($LASTEXITCODE -ne 0) {
            throw "APK 签名失败，退出码 $LASTEXITCODE。"
        }
    }
    finally {
        Remove-Item Env:\BILITOGETHER_SIGNING_PASSWORD -ErrorAction SilentlyContinue
    }

    & $apksigner verify --verbose --print-certs $signedApkStaging | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "APK 签名验证失败，退出码 $LASTEXITCODE。"
    }

    $finalApk = Copy-ApkToRelease -SourceApk $signedApkStaging -BaseName $BaseName

    # 清理临时签名文件与空 staging 目录
    Remove-Item -LiteralPath $signedApkStaging -ErrorAction SilentlyContinue
    if ($alignedApk) {
        Remove-Item -LiteralPath $alignedApk -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $stagingDir) {
        $remaining = Get-ChildItem -LiteralPath $stagingDir -Force -ErrorAction SilentlyContinue
        if (-not $remaining) {
            Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $hash = (Get-FileHash -Algorithm SHA256 $finalApk).Hash
    Write-BuildInfo "APK 构建完成：$finalApk"
    Write-BuildInfo "SHA-256: $hash"
    Write-BuildWarn "签名密钥备份目录：$($script:SigningDir)"
    return $finalApk
}
