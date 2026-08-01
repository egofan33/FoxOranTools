#Requires -Version 5.1
#=============================================================================
# 05-Resolvers.ps1 - 依赖版本与下载地址解析
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================


# =============================================================================
# 网络 API 解析：JDK / Android SDK / Node.js
# =============================================================================

function Get-TemurinBinaryJdkCandidate {
    <#
        Adoptium 二进制端点（/v3/binary/latest/...）会返回 302 重定向到实际下载包。
        当元数据 API 不稳定时，直接请求该端点通常更可靠。
    #>
    $downloadUrl = $script:TemurinBinaryUrl -f $script:RequiredJdkMajorVersion
    return [pscustomobject]@{
        Source  = "AdoptiumBinary"
        Url     = $downloadUrl
        Version = $null
        Name    = "jdk-$($script:RequiredJdkMajorVersion)-temurin.zip"
        Sha256  = $null
    }
}

function Get-AdoptiumApiJdkCandidate {
    <#
        通过 Adoptium Release Info API 解析最新 JDK 下载链接。
        依次尝试直连与配置的代理镜像。
    #>
    $url = $script:TemurinReleaseInfoUrl -f $script:RequiredJdkMajorVersion
    $urls = foreach ($prefix in $script:JdkProxyPrefixes) { "$prefix$url" }
    $lastError = $null

    for ($i = 0; $i -lt $urls.Count; $i++) {
        $currentUrl = $urls[$i]
        Write-BuildInfo "正在通过 Adoptium API 获取 JDK 下载信息（尝试 $($i + 1)/$($urls.Count)）..."

        try {
            $release = Invoke-RestMethod `
                -Uri $currentUrl `
                -Headers @{"User-Agent" = $script:UserAgent} `
                -TimeoutSec $script:RequestTimeoutSec `
                -ErrorAction Stop

            $firstRelease = $release | Select-Object -First 1
            if (-not $firstRelease) {
                throw "Adoptium API 未返回 release 数据。"
            }

            $binary = $firstRelease.binaries | Select-Object -First 1
            if (-not $binary -or -not $binary.package) {
                throw "Adoptium 返回的数据缺少 binary 包信息。"
            }

            $pkg = $binary.package
            $downloadUrl = $pkg.link
            $name = $pkg.name
            $sha256 = if ($pkg.checksum) { $pkg.checksum } else { $null }

            # 如果 API 没有返回链接，回退到直接二进制 URL
            if (-not $downloadUrl -or $downloadUrl -notmatch '^https?://') {
                $downloadUrl = $script:TemurinBinaryUrl -f $script:RequiredJdkMajorVersion
                $name = "jdk-$($script:RequiredJdkMajorVersion).zip"
            }

            return [pscustomobject]@{
                Source  = "AdoptiumApi"
                Url     = $downloadUrl
                Version = $firstRelease.release_name
                Name    = $name
                Sha256  = $sha256
            }
        }
        catch {
            $lastError = $_
            Write-BuildWarn "Adoptium API 请求失败：$($_.Exception.Message)"
        }
    }

    Write-BuildWarn "Get-AdoptiumApiJdkCandidate: 无法获取 JDK 下载链接，已尝试 $($urls.Count) 个端点。最后一次错误：$lastError"
    return $null
}

function Get-GitHubTemurinJdkCandidate {
    <#
        从 Adoptium GitHub Releases 解析 Windows x64 JDK asset。
        作为 Adoptium API 全部失败时的兜底源。
        注意：仓库中存在仅含元数据/源码的 -ga release（如 jdk-21.0.12-ga），
        /releases/latest 可能命中它，因此改为遍历最近的 releases，
        取第一个含目标 Windows x64 JDK zip 资产的 release。
        下载地址不裸连 GitHub：按 JdkProxyPrefixes 为每个镜像源生成一个
        候选（镜像优先，直连排最后），由调用方依次尝试。
    #>
    $repo = $script:TemurinGitHubRepo -f $script:RequiredJdkMajorVersion
    $url = $script:TemurinGitHubReleaseApi -f $repo
    $urls = foreach ($prefix in $script:JdkProxyPrefixes) { "$prefix$url" }
    $lastError = $null

    for ($i = 0; $i -lt $urls.Count; $i++) {
        $currentUrl = $urls[$i]
        Write-BuildInfo "正在通过 GitHub Releases 获取 JDK 下载信息（尝试 $($i + 1)/$($urls.Count)）..."

        try {
            $response = Invoke-RestMethod `
                -Uri $currentUrl `
                -Headers @{"User-Agent" = $script:UserAgent} `
                -TimeoutSec $script:RequestTimeoutSec `
                -ErrorAction Stop

            # 兼容单对象（/releases/latest）与数组（/releases）两种响应
            $releases = @($response) |
                Where-Object { -not $_.draft } |
                Sort-Object { [datetime]$_.published_at } -Descending

            foreach ($release in $releases) {
                $asset = @($release.assets) |
                    Where-Object { $_.name -match '^OpenJDK.*-jdk_x64_windows_hotspot_.*\.zip$' } |
                    Select-Object -First 1

                if ($asset) {
                    # 为每个镜像前缀生成一个候选：镜像优先，直连（空前缀）排最后
                    $orderedPrefixes = @($script:JdkProxyPrefixes | Where-Object { -not [string]::IsNullOrEmpty($_) })
                    $orderedPrefixes += @($script:JdkProxyPrefixes | Where-Object { [string]::IsNullOrEmpty($_) })
                    if ($orderedPrefixes.Count -eq 0) { $orderedPrefixes = @("") }

                    $assetCandidates = foreach ($prefix in $orderedPrefixes) {
                        $sourceLabel = if ([string]::IsNullOrEmpty($prefix)) {
                            "GitHubReleases"
                        }
                        else {
                            "GitHubReleases ($($prefix.TrimEnd('/')))"
                        }
                        [pscustomobject]@{
                            Source  = $sourceLabel
                            Url     = "$prefix$($asset.browser_download_url)"
                            Version = $release.tag_name
                            Name    = $asset.name
                            Sha256  = $null
                        }
                    }

                    return $assetCandidates
                }
            }

            throw "在最近的 GitHub releases 中未找到 Windows x64 JDK zip asset。"
        }
        catch {
            $lastError = $_
            Write-BuildWarn "GitHub Releases 请求失败：$($_.Exception.Message)"
        }
    }

    Write-BuildWarn "Get-GitHubTemurinJdkCandidate: 无法获取 GitHub 下载链接，已尝试 $($urls.Count) 个端点。最后一次错误：$lastError"
    return $null
}

function Get-TemurinJdkCandidates {
    <#
        返回一组 JDK 下载候选对象，按优先级排序：
        1. Adoptium 二进制端点（直接 302 下载）
        2. Adoptium API（直连 + 代理）
        3. GitHub Releases（直连 + 代理）
    #>
    $candidates = @()

    # 1. 二进制端点
    $candidates += Get-TemurinBinaryJdkCandidate

    # 2. Adoptium API
    $apiCandidate = Get-AdoptiumApiJdkCandidate
    if ($apiCandidate) {
        $candidates += $apiCandidate
    }

    # 3. GitHub Releases（每个镜像前缀一个候选）
    $ghCandidates = Get-GitHubTemurinJdkCandidate
    if ($ghCandidates) {
        $candidates += $ghCandidates
    }

    return $candidates
}

function Get-LatestAndroidCmdlineToolsUrl {
    $lastError = $null

    for ($i = 0; $i -lt $script:MaxRetries; $i++) {
        try {
            $xmlUrl = $script:AndroidRepositoryXml
            if ($script:AndroidUseMirror) {
                $xmlUrl = "$($script:AndroidMirrorBase.TrimEnd('/'))/repository2-1.xml"
                Write-BuildInfo "使用镜像源解析 Android SDK 仓库：$xmlUrl"
            }
            else {
                Write-BuildInfo "使用官方源解析 Android SDK 仓库：$xmlUrl"
            }

            $xmlText = Invoke-RestMethod `
                -Uri $xmlUrl `
                -Headers @{"User-Agent" = $script:UserAgent} `
                -TimeoutSec $script:RequestTimeoutSec `
                -ErrorAction Stop

            [xml]$xml = $xmlText

            # 查找 cmdline-tools 包，取 major 版本最大的
            $pkg = $xml.SelectNodes("//remotePackage[starts-with(@path,'cmdline-tools;')]") |
                Sort-Object {
                    $major = $_.revision.major
                    if (-not $major) { $major = 0 }
                    [int]$major
                } -Descending |
                Select-Object -First 1

            if (-not $pkg) {
                throw "在 Android 仓库 XML 中未找到 cmdline-tools 包。"
            }

            $archive = $pkg.archives.archive |
                Where-Object { $_.'host-os' -eq "windows" -or -not $_.'host-os' } |
                Select-Object -First 1

            if (-not $archive -or -not $archive.complete.url) {
                throw "未找到 Windows 版 cmdline-tools 归档。"
            }

            $url = $archive.complete.url
            if ($url -notmatch '^https?://') {
                # 相对路径
                if ($script:AndroidUseMirror) {
                    $url = "$($script:AndroidMirrorBase.TrimEnd('/'))/$url"
                }
                else {
                    $url = "https://dl.google.com/android/repository/$url"
                }
            }
            elseif ($script:AndroidUseMirror) {
                # 绝对路径但替换为镜像源
                $url = $url -replace '^https?://dl\.google\.com/android/repository', $script:AndroidMirrorBase.TrimEnd('/')
            }

            return [pscustomobject]@{
                Url           = $url
                Path          = $pkg.path
                Version       = "$($pkg.revision.major).$($pkg.revision.minor).$($pkg.revision.micro)"
                RepositoryXml = $xml
            }
        }
        catch {
            $lastError = $_
            Write-BuildWarn "Android 仓库解析失败：$($_.Exception.Message)"
        }
    }

    throw "Get-LatestAndroidCmdlineToolsUrl: 无法获取 Android SDK 下载链接，已重试 $($script:MaxRetries) 次。最后一次错误：$lastError"
}

function ConvertTo-NumericVersionPrefix {
    <#
        将版本表达式规范化为前导连续数字段。
        例如 'v20.11.0' -> '20.11.0'，'>=20.x' -> '20'，无法解析时返回 'latest'。
    #>
    param([Parameter(Mandatory = $true)][string]$Raw)

    $clean = $Raw.Trim() -replace '^[\^~>=v\s]+', ''
    $numericParts = @()
    foreach ($part in ($clean -split '\.')) {
        if ($part -match '^\d+$') { $numericParts += $part } else { break }
    }
    if ($numericParts.Count -eq 0) { return 'latest' }
    return ($numericParts -join '.')
}

function Get-TargetNodeVersion {
    <#
        从 .nvmrc 或 package.json engines.node 读取目标 Node 版本。
        返回 'latest' 或类似 '20', '20.11.0' 的字符串。
    #>
    $nvmrcPath = Join-Path $script:MobileRoot ".nvmrc"
    if (Test-Path -LiteralPath $nvmrcPath) {
        $v = (Get-Content -LiteralPath $nvmrcPath -Raw -ErrorAction Stop).Trim()
        if ($v -and $v -notmatch '^\s*$') {
            if ($v -eq 'lts/*') { $v = 'latest' }
            else { $v = ConvertTo-NumericVersionPrefix $v }
            Write-BuildInfo "从 .nvmrc 读取到 Node 目标版本：$v"
            return $v
        }
    }

    $packageJsonPath = Join-Path $script:MobileRoot "package.json"
    if (Test-Path -LiteralPath $packageJsonPath) {
        try {
            $json = Get-Content -LiteralPath $packageJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
            $engine = $null
            if ($json.engines -and $json.engines.PSObject -and $json.engines.node) {
                $engine = $json.engines.node
            }
            if ($engine) {
                $clean = ConvertTo-NumericVersionPrefix $engine
                Write-BuildInfo "从 package.json engines.node 读取到 Node 目标版本：$clean"
                return $clean
            }
        }
        catch {
            Write-BuildWarn "读取 package.json 的 engines.node 失败：$($_.Exception.Message)"
        }
    }

    return 'latest'
}

function Test-VersionMatchesTarget {
    <#
        判断版本号是否满足目标版本前缀（如 20.11.0 满足 20，但 200.0.0 不满足 20）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Target
    )
    if ($Target -eq 'latest' -or [string]::IsNullOrWhiteSpace($Target)) { return $true }
    $cleanVersion = $Version -replace '^v', ''
    $cleanTarget = $Target -replace '^[\^~>=v\s]+', ''

    $versionParts = $cleanVersion -split '\.'
    $targetParts = $cleanTarget -split '\.'

    for ($i = 0; $i -lt $targetParts.Count; $i++) {
        if ($i -ge $versionParts.Count) { return $false }
        if ($versionParts[$i] -ne $targetParts[$i]) { return $false }
    }
    return $true
}

function Get-LatestNodeUrl {
    $url = $script:NodeDistIndexUrl
    $urls = @($url, "$($script:ProxyPrefix)$url")
    $lastError = $null

    for ($i = 0; $i -lt $script:MaxRetries; $i++) {
        $currentUrl = $urls[$i % $urls.Count]
        Write-BuildInfo "正在获取 Node.js 版本列表（尝试 $($i + 1)/$($script:MaxRetries)）..."

        try {
            $index = Invoke-RestMethod `
                -Uri $currentUrl `
                -Headers @{"User-Agent" = $script:UserAgent} `
                -TimeoutSec $script:RequestTimeoutSec `
                -ErrorAction Stop

            $target = Get-TargetNodeVersion
            $release = $null

            if ($target -eq 'latest') {
                # 优先选择最新 LTS（更适配 RN/Gradle 构建）；索引无 LTS 标记时回退到首条
                $release = $index | Where-Object { $_.lts } | Select-Object -First 1
                if (-not $release) {
                    $release = $index | Select-Object -First 1
                }
            }
            else {
                $release = $index |
                    Where-Object { Test-VersionMatchesTarget -Version $_.version -Target $target } |
                    Select-Object -First 1
            }

            if (-not $release) {
                throw "未找到 Node.js 目标版本 $target。"
            }

            $version = $release.version
            $name = "node-$version-$($script:NodeAssetSuffix)"
            $downloadUrl = "https://nodejs.org/dist/$version/$name"

            return [pscustomobject]@{
                Url     = $downloadUrl
                Version = $version
                Name    = $name
            }
        }
        catch {
            $lastError = $_
            Write-BuildWarn "Node.js 版本列表请求失败：$($_.Exception.Message)"
        }
    }

    throw "Get-LatestNodeUrl: 无法获取 Node.js 下载链接，已重试 $($script:MaxRetries) 次。最后一次错误：$lastError"
}

function Get-JavaMajorVersion {
    param([Parameter(Mandatory = $true)][string]$JavaExe)

    # 使用 .NET Process 直接读取 stderr，避免 Windows PowerShell 5.1 将 stderr 包装成错误记录。
    $psi = New-Object System.Diagnostics.ProcessStartInfo($JavaExe, '-version')
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $errOut = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    $firstLine = ($errOut -split "`r?`n") | Where-Object { $_ } | Select-Object -First 1

    # Java 9+ : "version \"21.0.0...\""
    if ($firstLine -match 'version\s+"(?<major>\d+)') {
        return [int]$Matches.major
    }
    # Java 8 及更早："version \"1.8.0_xxx\""
    if ($firstLine -match 'version\s+"1\.(?<major>\d+)') {
        return [int]$Matches.major
    }
    return $null
}

function Get-RequiredJdkMajorVersion {
    <#
        返回目标 JDK 主版本（当前配置为 17）。
    #>
    return $script:RequiredJdkMajorVersion
}

function Get-FlutterSdkReleaseInfo {
    <#
        从 Flutter 发布元数据解析 stable 通道当前版本的下载信息。
        优先国内镜像，失败回退官方源；下载地址的 host 与元数据来源保持一致。
        返回 @{ Version; ArchiveUrl; Sha256 }
    #>
    $metaPath = 'flutter_infra_release/releases/releases_windows.json'
    $metaUrls = @(
        "$($script:FlutterStorageBaseUrl.TrimEnd('/'))/$metaPath",
        "$($script:FlutterOfficialStorageBaseUrl.TrimEnd('/'))/$metaPath"
    ) | Select-Object -Unique

    $lastError = $null
    foreach ($metaUrl in $metaUrls) {
        try {
            Write-BuildInfo "正在获取 Flutter stable 版本信息：$metaUrl"
            $meta = Invoke-RestMethod -Uri $metaUrl -TimeoutSec $script:RequestTimeoutSec -ErrorAction Stop
            $stableHash = $meta.current_release.stable
            $release = $meta.releases | Where-Object { $_.hash -eq $stableHash } | Select-Object -First 1
            if (-not $release) { throw "元数据中未找到 stable 通道当前版本（hash: $stableHash）。" }
            $archiveHost = ([System.Uri]$metaUrl).Host
            $archiveUrl = "https://$archiveHost/flutter_infra_release/releases/$($release.archive)"
            return @{ Version = [string]$release.version; ArchiveUrl = $archiveUrl; Sha256 = [string]$release.sha256 }
        }
        catch {
            $lastError = $_
            Write-BuildWarn "获取 Flutter 版本信息失败（$metaUrl）：$($_.Exception.Message)"
        }
    }
    throw "无法获取 Flutter SDK 版本信息（镜像与官方源均失败）：$($lastError.Exception.Message)"
}

function Get-AndroidBuildToolsVersion {
    <#
        从仓库 XML 解析与目标 API 级别匹配的最新 build-tools 版本。
    #>
    param(
        [Parameter(Mandatory = $true)][xml]$RepoXml,
        [Parameter()][int]$TargetApiLevel = $script:AndroidTargetApiLevel
    )

    $versions = $RepoXml.SelectNodes("//remotePackage[starts-with(@path,'build-tools;')]") |
        ForEach-Object { $_.path -replace '^build-tools;', '' } |
        Where-Object {
            $candidate = $_
            try {
                $v = [version]$candidate
                $v.Major -eq $TargetApiLevel
            }
            catch {
                Write-BuildWarn "跳过无法解析的 build-tools 版本号: $candidate"
                $false
            }
        } |
        Sort-Object { [version]$_ } -Descending |
        Select-Object -First 1

    if (-not $versions) {
        $versions = $RepoXml.SelectNodes("//remotePackage[starts-with(@path,'build-tools;')]") |
            ForEach-Object { $_.path -replace '^build-tools;', '' } |
            Sort-Object {
                $candidate = $_
                try { [version]$candidate }
                catch {
                    Write-BuildWarn "跳过无法解析的 build-tools 版本号: $candidate"
                    [version]"0.0"
                }
            } -Descending |
            Select-Object -First 1
    }

    if (-not $versions) {
        throw "无法从仓库 XML 解析 build-tools 版本。"
    }
    return $versions
}
