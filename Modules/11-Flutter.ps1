#Requires -Version 5.1
#=============================================================================
# 11-Flutter.ps1 - Flutter 构建与 pub 依赖处理
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================

function Get-PubspecDevGitDependencies {
    <#
        解析 pubspec.yaml 的 dev_dependencies 段，返回其中的 git 依赖列表
        （@{ Name; Url }）。用缩进感知解析器，兼容任意缩进与注释，不引入 YAML 库。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PubspecPath
    )
    if (-not (Test-Path -LiteralPath $PubspecPath)) { return @() }
    $content = Get-Content -LiteralPath $PubspecPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($content)) { return @() }

    $doc = ConvertFrom-YamlLite -Content $content
    if (-not $doc.Contains('dev_dependencies')) { return @() }

    $devDeps = $doc['dev_dependencies']
    if ($devDeps -isnot [System.Collections.IDictionary]) { return @() }

    $result = @()
    foreach ($name in $devDeps.Keys) {
        $dep = $devDeps[$name]
        if ($dep -is [System.Collections.IDictionary] -and $dep.Contains('git')) {
            $git = $dep['git']
            if ($git -is [System.Collections.IDictionary] -and $git.Contains('url')) {
                $url = $git['url']
                if ($null -ne $url) {
                    $result += [pscustomobject]@{ Name = $name; Url = [string]$url }
                }
            }
        }
    }
    return $result
}

function Set-FlutterDevGitDepsHosted {
    <#
        dev_dependencies 中的 git 依赖不参与构建产物，但 pub get 仍须全量 mirror clone
        （巨型 monorepo 经免费镜像可能数十分钟且进度不可见，体验等同卡死）。
        对其中在 pub 镜像存在同名 hosted 包的，经官方 pubspec_overrides.yaml 覆盖为
        hosted（不修改原 pubspec.yaml；pubspec_overrides.yaml 官方建议不入库，
        本就是本地覆盖语义），让 pub get 经 PUB_HOSTED_URL 镜像秒下。

        关键：新版 pub 在 pubspec_overrides.yaml 存在时，以其 dependency_overrides
        **替换**（而非合并）pubspec.yaml 中的 dependency_overrides。因此生成的文件
        必须完整保留 pubspec.yaml 原有 override 条目，否则项目原有 git 覆盖
        （如 fork 包替换）会丢失，引发版本求解冲突。
        本函数每次运行都按"原 overrides 原文 + 新增 hosted 覆盖"重建该文件（幂等）。
    #>
    $pubspecPath = Join-Path $script:MobileRoot 'pubspec.yaml'
    $overridesPath = Join-Path $script:MobileRoot 'pubspec_overrides.yaml'

    # 1. 找出 dev git 依赖中可转 hosted 的包
    $hostedOverrides = @()
    $devGitDeps = @(Get-PubspecDevGitDependencies -PubspecPath $pubspecPath)
    if ($devGitDeps.Count -gt 0) {
        $hostedBase = if (-not [string]::IsNullOrWhiteSpace($env:PUB_HOSTED_URL)) { $env:PUB_HOSTED_URL } else { $script:PubHostedUrl }
        foreach ($dep in $devGitDeps) {
            try {
                $null = Invoke-RestMethod -Uri "$($hostedBase.TrimEnd('/'))/api/packages/$($dep.Name)" -TimeoutSec $script:RequestTimeoutSec -ErrorAction Stop
                $hostedOverrides += $dep.Name
                Write-BuildInfo "dev git 依赖 $($dep.Name) 在 pub 镜像存在 hosted 版本，将覆盖为 hosted（跳过 git clone）。"
            }
            catch {
                Write-BuildWarn "dev git 依赖 $($dep.Name) 在 pub 镜像无同名 hosted 包，保留 git 源：$($dep.Url)"
            }
        }
    }

    # 无新增覆盖且未生成过文件：无需动作
    if ($hostedOverrides.Count -eq 0 -and -not (Test-Path -LiteralPath $overridesPath)) { return }

    # 2. 提取 pubspec.yaml 原有 dependency_overrides 段原文与包名（必须完整保留）
    $pubspecContent = Get-Content -LiteralPath $pubspecPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -eq $pubspecContent) { $pubspecContent = '' }
    $origSection = Get-YamlLiteSectionRaw -Content $pubspecContent -Key 'dependency_overrides'
    $origBody = ''
    $origNames = @()
    if ($origSection.Found) {
        $origBody = $origSection.Body
        $origDoc = ConvertFrom-YamlLite -Content ("dependency_overrides:`r`n" + $origBody)
        $overridesMap = $origDoc['dependency_overrides']
        if ($overridesMap -is [System.Collections.IDictionary]) {
            $origNames = @($overridesMap.Keys | ForEach-Object { [string]$_ })
        }
    }

    # 3. 重建文件：原 overrides 原文 + 新增 hosted 覆盖（与原条目同名的跳过，尊重项目原配置）
    $toAdd = @($hostedOverrides | Where-Object { $origNames -notcontains $_ })
    if ($hostedOverrides.Count -eq 0 -and [string]::IsNullOrWhiteSpace($origBody)) {
        # 既无原 overrides 也无新增：若之前误生成过文件则删除，避免空 overrides 干扰求解
        if (Test-Path -LiteralPath $overridesPath) {
            Remove-Item -LiteralPath $overridesPath -Force -ErrorAction SilentlyContinue
        }
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('dependency_overrides:')
    if (-not [string]::IsNullOrWhiteSpace($origBody)) {
        foreach ($l in ($origBody -split '\r?\n')) { $lines.Add($l) }
    }
    foreach ($name in $toAdd) { $lines.Add("  $name`: any") }
    $newContent = ($lines -join "`r`n") + "`r`n"

    $existing = Get-Content -LiteralPath $overridesPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($existing -eq $newContent) {
        Write-BuildInfo 'pubspec_overrides.yaml 已是最新，无需修改。'
        return
    }
    [System.IO.File]::WriteAllText($overridesPath, $newContent, (New-Object System.Text.UTF8Encoding($false)))
    Write-BuildInfo "已重建 pubspec_overrides.yaml（保留原 overrides $(($origNames.Count)) 项，新增 hosted 覆盖：$($toAdd -join ', ')），原 pubspec.yaml 未改动。"
}

function Assert-FlutterSymlinkSupport {
    <#
        Flutter Windows 插件构建要求当前用户可创建符号链接（symlink）。
        Windows 默认仅管理员可创建；开启"开发者模式"后普通用户亦可（立即生效，无需重启）。
        检测失败时：管理员自动写入注册表开启开发者模式；非管理员抛出明确手动开启指引。
    #>
    $probeParent = Join-Path $env:TEMP ('symlink-probe-' + [guid]::NewGuid().ToString('N'))
    $probeTarget = Join-Path $probeParent 'target'
    $probeLink = Join-Path $probeParent 'link'

    $supported = $false
    try {
        New-Item -ItemType Directory -Path $probeTarget -Force -ErrorAction Stop | Out-Null
        # 用 mklink 实测：PS 5.1 的 New-Item -ItemType SymbolicLink 写死了管理员前置检查，
        # 开发者模式下的普通用户会被误报；flutter/Dart 直接调系统 API，与 mklink 行为一致
        $null = cmd /c "mklink /D `"$probeLink`" `"$probeTarget`"" 2>&1
        $supported = ($LASTEXITCODE -eq 0)
    }
    catch {
        $supported = $false
    }
    finally {
        Remove-Item -LiteralPath $probeParent -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($supported) {
        Write-BuildInfo '符号链接（symlink）支持检测通过。'
        return
    }

    Write-BuildWarn '当前用户无法创建符号链接（Flutter Windows 插件构建必需）。'

    $isAdmin = Test-IsAdmin

    if ($isAdmin) {
        try {
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
                -Name 'AllowDevelopmentWithoutDevLicense' -Value 1 -Type DWord -ErrorAction Stop
            Write-BuildInfo '检测到管理员权限，已自动开启 Windows 开发者模式（AllowDevelopmentWithoutDevLicense=1，立即生效无需重启）。'
            return
        }
        catch {
            Write-BuildWarn "自动开启开发者模式失败：$($_.Exception.Message)"
        }
    }

    throw @"
Flutter 在 Windows 上构建插件要求符号链接支持，但当前用户无创建权限。
请开启 Windows 开发者模式（设置 -> 系统 -> 开发者选项 -> 开发人员模式），
或执行：start ms-settings:developers
开启后无需重启，重新运行本脚本即可。
"@
}

function Remove-PubGitCache {
    <#
        删除 pub 的 git 依赖缓存（Pub\Cache\git）。
        早前 clone 被网络中断/代理截断会留下残缺对象库（rev-list 能解析引用，
        但 checkout 报 unable to read tree），pub 每次都复用该坏缓存导致
        pub get 必败；删除后 pub 会自动重新克隆，安全无副作用。
        优先 Remove-Item；残留锁导致失败时回退 robocopy 镜像空目录法。
        返回是否删除成功。
    #>
    $pubCacheRoot = if (-not [string]::IsNullOrWhiteSpace($env:PUB_CACHE)) {
        $env:PUB_CACHE
    }
    else {
        Join-Path $env:LOCALAPPDATA 'Pub\Cache'
    }
    $gitCache = Join-Path $pubCacheRoot 'git'
    if (-not (Test-Path -LiteralPath $gitCache)) { return $true }

    Write-BuildWarn "正在清理损坏的 pub git 依赖缓存：$gitCache"
    return (Remove-DirectoryRobust -Path $gitCache)
}

function Set-PubCacheGitHubDownloadMirror {
    <#
        pub get 之后调用：扫描 pub 缓存中插件包的 android/build.gradle(.kts)，
        把 GitHub Releases 下载 URL 改写为镜像前缀 URL（幂等）。
        背景：media_kit_libs_* 等插件在 Gradle 配置阶段经 HTTP 从 GitHub Releases
        拉取预编译 jar；git 通道的 url.insteadOf 注入只影响 git 协议，管不到该
        HTTP 下载，国内直连慢且易挂起。改写走 download.proxyPrefix 文件代理
        （与工具箱自身文件下载同一通道）。
    #>
    if ([string]::IsNullOrWhiteSpace($script:ProxyPrefix)) { return }

    $pubCacheRoot = if (-not [string]::IsNullOrWhiteSpace($env:PUB_CACHE)) { $env:PUB_CACHE } else { Join-Path $env:LOCALAPPDATA 'Pub\Cache' }
    $scanRoots = @('git', 'hosted') | ForEach-Object { Join-Path $pubCacheRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }
    if ($scanRoots.Count -eq 0) { return }

    $mirrorPrefix = "$($script:ProxyPrefix)https://github.com/"
    $pattern = 'https://github\.com/([^\s''"()\[\]]+/releases/download/[^\s''"()\[\]]+)'
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $total = 0
    foreach ($root in $scanRoots) {
        $files = Get-ChildItem -LiteralPath $root -Recurse -Include 'build.gradle', 'build.gradle.kts' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '[\\/]android[\\/]' }
        foreach ($file in $files) {
            $content = [System.IO.File]::ReadAllText($file.FullName)
            $newContent = [regex]::Replace($content, $pattern, "$mirrorPrefix`$1")
            if ($newContent -ne $content) {
                [System.IO.File]::WriteAllText($file.FullName, $newContent, $utf8NoBom)
                $count = ([regex]::Matches($newContent, [regex]::Escape($mirrorPrefix))).Count
                Write-BuildInfo "已将插件 Gradle 脚本中的 GitHub Releases 下载地址改写为镜像（$count 处）：$($file.FullName)"
                $total += $count
            }
        }
    }
    if ($total -gt 0) {
        Write-BuildInfo "GitHub Releases 下载地址镜像改写完成，共 $total 处。"
    }
}

function Invoke-FlutterBuildApk {
    <#
        Flutter 项目构建：flutter pub get → flutter build apk --release。
        pub 依赖与引擎产物走国内镜像环境变量（PUB_HOSTED_URL / FLUTTER_STORAGE_BASE_URL，
        由 Start-ReleaseBuild 注入）；flutter 内部调用 gradle，GRADLE_USER_HOME 短路径、
        阿里云 Maven 镜像、4G 堆等现有 Gradle 防线对其同样生效。
        pub get 阶段对 git 依赖缓存损坏（unable to read tree 等）做清缓存自愈重试。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FlutterHome
    )

    $flutterBat = Join-Path $FlutterHome 'bin\flutter.bat'
    if (-not (Test-Path -LiteralPath $flutterBat)) {
        throw "未找到 flutter.bat：$flutterBat"
    }

    # Flutter Windows 插件构建硬性要求 symlink 支持（开发者模式）
    Assert-FlutterSymlinkSupport

    Push-Location $script:MobileRoot
    # Gradle/javac 经 Flutter 以 UTF-8 输出诊断，中文 Windows 控制台默认按 GBK 解码
    # 子进程输出会产生乱码并污染 Tee 捕获的日志；构建期间切换为 UTF-8 解码，
    # finally 恢复原值（无控制台宿主时静默跳过）
    $prevConsoleOutputEncoding = $null
    try { $prevConsoleOutputEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
    try {
        # dev git 依赖（如 jnigen 这类巨型 monorepo 子包）有 hosted 版本时覆盖，
        # 避免 pub get 全量 mirror clone 大仓库卡死
        Set-FlutterDevGitDepsHosted

        # pub get（含 git 依赖缓存损坏自愈重试）：早前 clone 被中断留下的残缺
        # 对象库会让 checkout 报 unable to read tree，pub 复用坏缓存导致必败；
        # 命中特征时清除 Pub\Cache\git 并重试一次，重试仍失败才抛出。
        $pubExitCode = 0
        $gitCacheRepaired = $false
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            Write-BuildInfo "正在执行 flutter pub get --verbose（第 $attempt/2 次）..."
            & $flutterBat pub get --verbose 2>&1 | Tee-Object -Variable pubLog | ForEach-Object {
                $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
                Write-Host $line
                if ($null -ne $script:BuildLogWriter) { $script:BuildLogWriter.WriteLine($line) }
            }
            $pubExitCode = $LASTEXITCODE
            if ($pubExitCode -eq 0) { break }

            $isGitCacheCorrupt = ($pubLog | Select-String -Pattern 'unable to read tree|Git error|GitException|bad object|loose object .* is corrupt|object file .* is empty' -Quiet)
            if (-not $gitCacheRepaired -and $isGitCacheCorrupt -and (Remove-PubGitCache)) {
                $gitCacheRepaired = $true
                Write-BuildWarn '检测到 pub git 依赖缓存损坏，已清除缓存，正在重试 pub get...'
                continue
            }
            break
        }
        if ($pubExitCode -ne 0) {
            $gitCachePath = Join-Path $(if (-not [string]::IsNullOrWhiteSpace($env:PUB_CACHE)) { $env:PUB_CACHE } else { Join-Path $env:LOCALAPPDATA 'Pub\Cache' }) 'git'
            if ($gitCacheRepaired) {
                throw "flutter pub get 失败，退出码 $pubExitCode。已清除损坏的 pub git 依赖缓存并重试仍失败，请检查 git 依赖仓库（GitHub 及镜像代理）连通性，或手动删除 $gitCachePath 后重试。"
            }
            throw "flutter pub get 失败，退出码 $pubExitCode。请检查网络或 pub 镜像（PUB_HOSTED_URL=$env:PUB_HOSTED_URL）连通性；若上方日志含 'unable to read tree'/'Git error'，则为 git 依赖缓存损坏，可手动删除 $gitCachePath 后重试。"
        }

        # pub 缓存中插件的 Gradle 脚本可能含 GitHub Releases 直连下载（如 media-kit
        # 预编译 jar），git 镜像管不到该 HTTP 下载，改写为文件代理前缀
        Set-PubCacheGitHubDownloadMirror

        # 构建（含 AGP 9+ 新 DSL 自愈重试）：旧 DSL 编写的 build.gradle(.kts) 在 AGP 9+
        # 下只读新 DSL 导致 apply Flutter Gradle plugin 失败，按官方过渡方案写入
        # android.newDsl=false 后重试一次；重试时 Gradle 缓存已热，耗时不长。
        $maxAttempts = 2
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            Write-BuildInfo "正在执行 flutter build apk --release --verbose（首次需下载引擎与依赖，耗时较长；第 $attempt/$maxAttempts 次）..."
            & $flutterBat build apk --release --verbose 2>&1 | Tee-Object -Variable buildLog | ForEach-Object {
                $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
                Write-Host $line
                if ($null -ne $script:BuildLogWriter) { $script:BuildLogWriter.WriteLine($line) }
            }
            if ($LASTEXITCODE -eq 0) { return }

            $isNewDslIssue = ($buildLog | Select-String -Pattern 'android\.newDsl|new DSL interface' -Quiet)
            if ($attempt -lt $maxAttempts -and $isNewDslIssue) {
                $gradleProps = Join-Path $script:AndroidDir 'gradle.properties'
                $propsContent = Get-Content -LiteralPath $gradleProps -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($propsContent -notmatch '(?m)^\s*android\.newDsl\s*=') {
                    Write-BuildWarn '检测到 AGP 9+ 新 DSL 兼容问题，正在向 gradle.properties 写入 android.newDsl=false 并重试...'
                    Add-Content -LiteralPath $gradleProps -Value "`r`nandroid.newDsl=false" -Encoding ASCII -ErrorAction Stop
                    continue
                }
                # 配置已存在仍报该 Fix：属 flutter_tools 模式匹配误报（真实错误在上方日志），
                # 重试无意义，直接抛出原始错误
                Write-BuildWarn '构建日志含 newDsl 提示但 gradle.properties 已有对应配置——该提示为误报，真实失败原因见上方 Gradle 输出。'
            }
            # transforms 缓存损坏自愈：上次构建中断/守护进程被强杀会留下产物缺失的缓存条目
            #（Failed to transform ... does not exist / has been removed），清理后重试一次
            $buildText = ($buildLog | Out-String)
            if ($attempt -lt $maxAttempts -and (Test-GradleTransformCorruption -LogText $buildText)) {
                Write-BuildWarn '检测到 Gradle transforms 缓存损坏（上次构建中断或守护进程被强杀所致），正在清理并重试...'
                Repair-CorruptedGradleTransforms -LogText $buildText -Gradlew (Join-Path $script:AndroidDir 'gradlew.bat')
                continue
            }
            Write-BuildFailureHint -LogText $buildText
            throw "flutter build apk --release 失败，退出码 $LASTEXITCODE。"
        }
    }
    finally {
        if ($null -ne $prevConsoleOutputEncoding) { try { [Console]::OutputEncoding = $prevConsoleOutputEncoding } catch { } }
        Pop-Location
    }
}
