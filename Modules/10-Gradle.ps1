#Requires -Version 5.1
#=============================================================================
# 10-Gradle.ps1 - Gradle 配置、缓存修复与构建
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================

function Set-GradleWrapperMirror {
    <#
        将 gradle-wrapper.properties 的 distributionUrl 替换为国内镜像，
        避免 Gradle Wrapper 下载超时。
        优先级：HEAD 连通性探测 → 华为云 > 腾讯云 → 均不可达则保留原始 URL。
        -WrapperPropsPath 可显式指定目标文件（cordova-android ≥15 的 wrapper 位于
        platforms\android\tools\ 下），缺省为平台根 gradle\wrapper\gradle-wrapper.properties。
    #>
    param([string]$WrapperPropsPath)
    $wrapperProps = if (-not [string]::IsNullOrWhiteSpace($WrapperPropsPath)) {
        $WrapperPropsPath
    }
    else {
        Join-Path $script:AndroidDir "gradle\wrapper\gradle-wrapper.properties"
    }
    if (-not (Test-Path -LiteralPath $wrapperProps)) {
        Write-BuildWarn "未找到 gradle-wrapper.properties，跳过 Gradle 镜像替换。"
        return
    }

    $lines = Get-Content -LiteralPath $wrapperProps -Encoding UTF8
    $found = $false
    $newLines = $null
    $originalUrl = $null

    foreach ($line in $lines) {
        if ($line -match '^\s*distributionUrl\s*=\s*(.+)$') {
            $found = $true
            $originalUrl = $Matches[1].Trim() -replace '\\:', ':'
            continue
        }
    }

    if (-not $found) {
        Write-BuildWarn "无法解析 gradle-wrapper.properties 中的 distributionUrl，跳过镜像替换。"
        return
    }

    Write-BuildInfo "原始 distributionUrl：$originalUrl"

    if ($originalUrl -notmatch 'gradle-(?<version>\d+\.\d+(?:\.\d+)?)-(?<type>all|bin)\.zip') {
        Write-BuildWarn "无法从 distributionUrl 提取 Gradle 版本，保留原始 URL。"
        return
    }

    $version = $Matches['version']
    $type = $Matches['type']

    $mirrors = @(
        @{ Name = '华为云'; Url = "https://mirrors.huaweicloud.com/gradle/gradle-$version-$type.zip" }
        @{ Name = '腾讯云'; Url = "https://mirrors.cloud.tencent.com/gradle/gradle-$version-$type.zip" }
    )

    $selectedMirror = $null
    foreach ($mirror in $mirrors) {
        Write-BuildInfo "探测 $($mirror.Name) Gradle 镜像连通性..."
        try {
            $iwrSplat = @{
                Uri         = $mirror.Url
                Method      = 'Head'
                TimeoutSec  = 10
                ErrorAction = 'Stop'
            }
            if ($PSVersionTable.PSVersion.Major -le 5) {
                $iwrSplat['UseBasicParsing'] = $true
            }
            $response = Invoke-WebRequest @iwrSplat
            $contentMb = [math]::Round($response.ContentLength / 1MB, 1)
            Write-BuildInfo "$($mirror.Name) 镜像可达（文件 $contentMb MB）。"
            $selectedMirror = $mirror
            break
        }
        catch {
            Write-BuildWarn "$($mirror.Name) 镜像不可达：$($_.Exception.Message)"
        }
    }

    if (-not $selectedMirror) {
        Write-BuildWarn "所有国内 Gradle 镜像均不可达，保留原始 distributionUrl（可能因超时失败）。"
        return
    }

    $escapedUrl = $selectedMirror.Url -replace ':', '\:'
    $newLines = foreach ($line in $lines) {
        if ($line -match '^\s*distributionUrl\s*=') {
            "distributionUrl=$escapedUrl"
        }
        else { $line }
    }

    # 无 BOM UTF8 写入：PS5.1 的 Set-Content -Encoding UTF8 会写 BOM，
    # Java Properties 不剥 BOM，distributionUrl 若在首行会因 key 被污染而静默失效
    [System.IO.File]::WriteAllLines($wrapperProps, [string[]]$newLines, (New-Object System.Text.UTF8Encoding($false)))
    Write-BuildInfo "已将 Gradle Wrapper distributionUrl 替换为 $($selectedMirror.Name) 镜像。"
    Write-BuildInfo "替换后：$escapedUrl"
}

function Set-GradleMirror {
    <#
        通过 GRADLE_USER_HOME/init.gradle 在运行时统一拦截并重定向所有仓库：
            google()             -> https://maven.aliyun.com/repository/google
            mavenCentral()       -> https://maven.aliyun.com/repository/central
            gradlePluginPortal() -> https://maven.aliyun.com/repository/gradle-plugin
            jcenter()            -> https://maven.aliyun.com/repository/central
        相比直接改 build.gradle/settings.gradle，init 脚本不会被 Expo prebuild --clean
        重建覆盖，且能覆盖 settings/pluginManagement/buildscript 等所有声明位置。

        写入前先探测阿里云镜像连通性；核心仓库（google/central）不可达则跳过，
        保留官方源，避免镜像故障导致构建直接失败。
    #>
    $probes = @(
        @{ Name = 'aliyun/google';        Url = 'https://maven.aliyun.com/repository/google/com/android/tools/build/gradle/8.5.0/gradle-8.5.0.pom' }
        @{ Name = 'aliyun/central';       Url = 'https://maven.aliyun.com/repository/central/org/reactivestreams/reactive-streams/1.0.4/reactive-streams-1.0.4.pom' }
        @{ Name = 'aliyun/gradle-plugin'; Url = 'https://maven.aliyun.com/repository/gradle-plugin/com/android/tools/build/gradle/8.5.0/gradle-8.5.0.pom' }
    )

    $status = @{}
    foreach ($probe in $probes) {
        # 判定标准：收到任意 < 500 的 HTTP 响应即视为仓库在线（404 仅说明该 artifact 不存在）
        $online = $false
        $detail = ''
        try {
            $iwrSplat = @{
                Uri         = $probe.Url
                Method      = 'Head'
                TimeoutSec  = 10
                ErrorAction = 'Stop'
            }
            if ($PSVersionTable.PSVersion.Major -le 5) { $iwrSplat['UseBasicParsing'] = $true }
            $response = Invoke-WebRequest @iwrSplat
            $online = ($response.StatusCode -lt 500)
            $detail = "HTTP $($response.StatusCode)"
        }
        catch {
            $webResponse = $_.Exception.Response
            if ($webResponse -ne $null) {
                $code = [int]$webResponse.StatusCode
                $online = ($code -lt 500)
                $detail = "HTTP $code"
            }
            else {
                $detail = $_.Exception.Message
            }
        }
        $status[$probe.Name] = $online
        if ($online) {
            Write-BuildInfo "镜像探测 $($probe.Name)：可达（$detail）。"
        }
        else {
            Write-BuildWarn "镜像探测 $($probe.Name)：不可达（$detail）。"
        }
    }

    if (-not ($status['aliyun/google'] -and $status['aliyun/central'])) {
        Write-BuildWarn "阿里云核心镜像（google/central）不可达，跳过 Maven 换源，保留官方仓库。"
        Write-BuildWarn "构建可能因拉取 dl.google.com / repo.maven.apache.org 过慢而超时。"
        return
    }

    if (-not $status['aliyun/gradle-plugin']) {
        Write-BuildWarn "aliyun/gradle-plugin 不可达，Gradle 插件解析可能较慢，但仍继续换源。"
    }

    $initScript = @'
// ============================================================================
// Aliyun Maven mirror init script (generated by FoxOranTools BuildHelper.psm1)
// Redirects google() / mavenCentral() / gradlePluginPortal() / jcenter()
// to https://maven.aliyun.com/repository/* at runtime.
// ============================================================================
import org.gradle.api.artifacts.repositories.MavenArtifactRepository

def aliyunMirrorOf = { String rawUrl ->
    if (rawUrl.contains('maven.aliyun.com')) { return null }
    if (rawUrl.contains('dl.google.com/dl/android/maven2') || rawUrl.contains('maven.google.com')) {
        return 'https://maven.aliyun.com/repository/google'
    }
    if (rawUrl.contains('repo.maven.apache.org/maven2') || rawUrl.contains('repo1.maven.org/maven2')
            || rawUrl.contains('jcenter.bintray.com')) {
        return 'https://maven.aliyun.com/repository/central'
    }
    if (rawUrl.contains('plugins.gradle.org')) {
        return 'https://maven.aliyun.com/repository/gradle-plugin'
    }
    return null
}

// repositories.all {} 是 live 回调：之后声明的仓库也会被拦截重定向
def aliyunRedirect = { repos ->
    repos.all { repo ->
        if (repo instanceof MavenArtifactRepository) {
            def mirror = aliyunMirrorOf(repo.url.toString())
            if (mirror != null) {
                println "[aliyun-mirror] ${repo.url} -> ${mirror}"
                repo.url = uri(mirror)
            }
        }
    }
}

gradle.settingsEvaluated { settings ->
    aliyunRedirect(settings.pluginManagement.repositories)
    aliyunRedirect(settings.dependencyResolutionManagement.repositories)
}

gradle.projectsLoaded {
    aliyunRedirect(gradle.rootProject.buildscript.repositories)
}

gradle.beforeProject { project ->
    aliyunRedirect(project.buildscript.repositories)
    aliyunRedirect(project.repositories)
}
'@

    $initPath = Join-Path $env:GRADLE_USER_HOME "init.gradle"
    Set-Content -LiteralPath $initPath -Value $initScript -Encoding ASCII -Force
    Write-BuildInfo "已写入阿里云 Maven 镜像 init 脚本：$initPath"
}

function Set-GradleMemory {
    <#
        强制 Gradle 守护进程使用 4G 堆内存，防止编译/合并资源时频繁 GC。

        项目级 android/gradle.properties 优先级高于 GRADLE_USER_HOME/gradle.properties，
        Expo/RN 模板默认 -Xmx2048m，因此必须在构建前改写项目级文件；
        GRADLE_USER_HOME 中的同名配置（Start-ReleaseBuild 写入）作为兜底。
    #>
    if ([string]::IsNullOrWhiteSpace($script:AndroidDir)) {
        Write-BuildWarn "Android 项目目录未确定，跳过 Gradle 内存配置。"
        return
    }
    $jvmArgsLine = 'org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=512m -XX:+HeapDumpOnOutOfMemoryError -Dfile.encoding=UTF-8'
    $projectProps = Join-Path $script:AndroidDir "gradle.properties"

    if (Test-Path -LiteralPath $projectProps) {
        $lines = Get-Content -LiteralPath $projectProps -Encoding UTF8
        $found = $false
        # 注意必须用 @() 包裹：单行文件时 foreach 仅返回字符串，+= 会退化为字符串拼接导致换行丢失
        $newLines = @(foreach ($line in $lines) {
            if ($line -match '^\s*org\.gradle\.jvmargs\s*=') {
                $found = $true
                if ($line -match '-Xmx4g') {
                    $line
                }
                else {
                    Write-BuildInfo "覆盖项目级 jvmargs：$line"
                    $jvmArgsLine
                }
            }
            else { $line }
        })
        if (-not $found) {
            $newLines += $jvmArgsLine
        }
        # 无 BOM UTF8 写入（理由同 gradle-wrapper.properties；保留原文件可能的非 ASCII 注释）
        [System.IO.File]::WriteAllLines($projectProps, [string[]]$newLines, (New-Object System.Text.UTF8Encoding($false)))
    }
    else {
        Set-Content -LiteralPath $projectProps -Value $jvmArgsLine -Encoding ASCII -Force
    }

    Write-BuildInfo "已强制 Gradle 守护进程堆内存为 4G（-Xmx4g，含 OOM 时自动导出堆转储）。"
}

function Test-BuildMemory {
    <#
        构建前内存预检：为 Gradle 4G 堆配置做风险预判。
        物理总内存 < 8GB 或当前可用 < 4GB 时输出醒目警告。
    #>
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $totalGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        # FreePhysicalMemory 单位为 KB
        $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        Write-BuildInfo "系统内存：总计 $totalGB GB，当前可用 $freeGB GB（Gradle 堆将固定分配 4 GB）。"

        if ($totalGB -lt 8) {
            Write-BuildWarn "物理内存总量不足 8 GB（当前 $totalGB GB），强制 4G 堆可能挤占系统与 IDE 内存。"
            Write-BuildWarn "建议：关闭其他大型程序后再编译；若仍出现 GC overhead / OutOfMemoryError，"
            Write-BuildWarn "      请把 android/gradle.properties 中 -Xmx4g 降为 -Xmx2g 后重试。"
        }
        elseif ($freeGB -lt 4) {
            Write-BuildWarn "当前可用内存不足 4 GB（仅剩 $freeGB GB），编译/合并文件时可能频繁 GC 甚至 OOM。"
            Write-BuildWarn "建议：先关闭浏览器、虚拟机等占内存程序，再开始编译。"
        }
    }
    catch {
        Write-BuildWarn "无法读取系统内存信息，跳过内存预检：$($_.Exception.Message)"
    }
}

function Test-BuildDiskSpace {
    <#
        构建前磁盘空间预检：NDK（解包约 4GB）、SDK 组件、Flutter/Gradle 缓存都是空间大户，
        工具盘（C:\APKTools 所在）或项目盘剩余不足时醒目提示（不阻断构建，由用户决策）。
        阈值：<3GB 严重警告 / <8GB 一般警告。同一磁盘只检测一次。
    #>
    $checkedDrives = @{}
    foreach ($targetPath in @($script:GlobalToolsRoot, $script:ProjectRoot)) {
        try {
            if ([string]::IsNullOrWhiteSpace($targetPath)) { continue }
            $rootPath = [System.IO.Path]::GetPathRoot($targetPath)
            if ([string]::IsNullOrWhiteSpace($rootPath)) { continue }
            $driveLetter = $rootPath.TrimEnd('\')
            if ($checkedDrives.ContainsKey($driveLetter)) { continue }
            $checkedDrives[$driveLetter] = $true

            $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$driveLetter'" -ErrorAction Stop
            if (-not $disk -or $null -eq $disk.FreeSpace) { continue }
            $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
            Write-BuildInfo "磁盘空间：$driveLetter 剩余 $freeGB GB。"

            if ($freeGB -lt 3) {
                Write-BuildWarn "$driveLetter 剩余空间严重不足（仅 $freeGB GB）——NDK/SDK 下载与 Gradle 缓存几乎必然写盘失败！"
                Write-BuildWarn "建议：先清理磁盘（菜单「清理缓存」、删除 C:\APKTools\g\ 下旧项目缓存、清空回收站），再开始编译。"
            }
            elseif ($freeGB -lt 8) {
                Write-BuildWarn "$driveLetter 剩余空间不足 8 GB（当前 $freeGB GB），若本次构建需下载 NDK/SDK（解包约 4GB）可能失败。"
                Write-BuildWarn "建议：预留至少 10 GB；可运行菜单「清理缓存」或删除 C:\APKTools\g\ 下旧项目缓存。"
            }
        }
        catch {
            Write-BuildWarn "无法读取磁盘空间信息，跳过该项预检：$($_.Exception.Message)"
        }
    }
}

function Test-WindowsLongPathSupport {
    <#
        检测系统是否启用 Win32 长路径支持（LongPathsEnabled）：
        - 已启用：直接通过；
        - 未启用且当前为管理员：自动写入注册表启用（需重启系统后完全生效）；
        - 未启用且非管理员：输出醒目警告与手动开启命令。
        注意即便开启，Android SDK 自带的 ninja 1.10 仍不支持长路径，
        因此本检测只作为双保险，主要防线仍是缩短 GRADLE_USER_HOME 前缀。
    #>
    $enabled = $false
    try {
        $value = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
            -Name LongPathsEnabled -ErrorAction Stop).LongPathsEnabled
        $enabled = ($value -eq 1)
    }
    catch {
        # 读取失败按未启用处理
    }

    if ($enabled) {
        Write-BuildInfo "系统已启用 Win32 长路径支持（LongPathsEnabled=1）。"
        return
    }

    # 检测当前进程是否拥有管理员权限
    $isAdmin = Test-IsAdmin

    if ($isAdmin) {
        try {
            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
                -Name LongPathsEnabled -Value 1 -Type DWord -ErrorAction Stop
            Write-BuildInfo "检测到管理员权限，已自动启用 Win32 长路径支持（LongPathsEnabled=1）。"
            Write-BuildWarn "该设置需重启系统后才完全生效；本次构建仍依赖短路径 GRADLE_USER_HOME 规避长路径问题。"
        }
        catch {
            Write-BuildWarn "尝试自动启用长路径支持失败：$($_.Exception.Message)"
        }
        return
    }

    Write-BuildWarn "系统未启用 Win32 长路径支持（LongPathsEnabled）。RN C++ 构建常因路径超 260 字符失败。"
    Write-BuildWarn "以管理员身份运行本脚本将自动启用；或手动执行以下命令后重启系统："
    Write-BuildWarn '  Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -Value 1'
}

function Remove-GradleTransformEntry {
    <#
        删除单个 transforms 缓存条目（Remove-DirectoryRobust 的语义化封装：
        Remove-Item 优先，超长路径/残留锁失败时回退 robocopy 镜像空目录法）。
    #>
    param([Parameter(Mandatory)][string]$Path)
    return (Remove-DirectoryRobust -Path $Path)
}

function Test-GradleTransformCorruption {
    <#
        判定构建日志是否为 transforms 缓存损坏签名，覆盖两类：
        1. 内容级损坏：immutable workspace ... have been modified（哈希校验不匹配）
        2. 结构级丢失：Failed to transform ... File/directory does not exist 或
           input property ... has been removed（上次构建中断/守护进程被强杀，
           缓存元数据仍在但产物文件缺失）
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$LogText)
    if ([string]::IsNullOrEmpty($LogText)) { return $false }
    if (($LogText -match 'immutable workspace') -and ($LogText -match 'have been modified')) { return $true }
    if ($LogText -match 'Failed to transform') {
        if (($LogText -match 'File/directory does not exist') -or ($LogText -match 'has been removed')) { return $true }
    }
    return $false
}

function Repair-CorruptedGradleTransforms {
    <#
        清理损坏的 transforms 缓存条目：从构建日志提取 transforms\<32位hash> 逐个删除；
        未能定位时兜底清空 GRADLE_USER_HOME 下全部 transforms 目录。
        内部先执行 gradlew --stop 释放缓存文件锁。
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$LogText,
        [Parameter(Mandatory)][string]$Gradlew
    )

    $hashDirs = [regex]::Matches($LogText, "([A-Za-z]:\\[^'`"]*?\\transforms\\[0-9a-f]{32})") |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

    # 停 daemon 释放缓存文件锁
    Push-Location $script:AndroidDir
    try { & $Gradlew --stop | Out-Null } catch { }
    finally { Pop-Location }

    if ($hashDirs.Count -gt 0) {
        foreach ($dir in $hashDirs) {
            if (Remove-GradleTransformEntry -Path $dir) {
                Write-BuildInfo "已删除损坏的 transforms 条目：$dir"
            }
            else {
                Write-BuildWarn "删除失败：$dir"
            }
        }
    }
    else {
        # 未能定位具体条目：兜底清空全部 transforms（重建需数分钟，但保证可恢复）
        Write-BuildWarn "未能从日志定位具体损坏条目，将清空整个 transforms 缓存目录。"
        $cachesRoot = Join-Path $env:GRADLE_USER_HOME "caches"
        Get-ChildItem -LiteralPath $cachesRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "transforms" } |
            Where-Object { Test-Path -LiteralPath $_ } |
            ForEach-Object {
                if (Remove-GradleTransformEntry -Path $_) {
                    Write-BuildInfo "已清空 transforms 目录：$_"
                }
            }
    }
}

function Repair-GradleTransformCache {
    <#
        构建前预检 transforms 缓存：清除上次构建被强制中断留下的残缺条目
        （缺 workspace 目录或 workspace 为空的半成品）。
        内容级损坏（哈希不匹配）由 Invoke-GradleAssembleRelease 在构建失败时自愈，
        此处只做零成本的结构级预检；被占用（锁定）的条目跳过。
    #>
    if ([string]::IsNullOrWhiteSpace($env:GRADLE_USER_HOME)) { return }
    $cachesRoot = Join-Path $env:GRADLE_USER_HOME "caches"
    if (-not (Test-Path -LiteralPath $cachesRoot)) { return }

    $transformRoots = Get-ChildItem -LiteralPath $cachesRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "transforms" } |
        Where-Object { Test-Path -LiteralPath $_ }

    $removed = 0
    foreach ($root in $transformRoots) {
        foreach ($entry in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $workspace = Join-Path $entry.FullName "workspace"
            $broken = (-not (Test-Path -LiteralPath $workspace)) -or
                      (-not (Get-ChildItem -LiteralPath $workspace -Force -ErrorAction SilentlyContinue | Select-Object -First 1))
            if (-not $broken) { continue }

            if (Remove-GradleTransformEntry -Path $entry.FullName) {
                $removed++
                Write-BuildInfo "预检清除残缺 transforms 缓存：$($entry.Name)"
            }
            else {
                Write-BuildWarn "无法清除 $($entry.FullName)（可能被占用），已跳过。"
            }
        }
    }
    if ($removed -gt 0) {
        Write-BuildInfo "transforms 预检完成，共清除 $removed 个残缺缓存条目（上次构建中断的残留）。"
    }
}

function Remove-StaleCxxBuildDirs {
    <#
        清理引用旧 GRADLE_USER_HOME 的 CMake 构建目录（node_modules 各包及 app 模块的 android\.cxx）。
        Gradle 对 CMake 配置任务的 transforms 输入按内容哈希判定 up-to-date：
        GRADLE_USER_HOME 变更后 transforms 内容哈希不变，CMake 配置被跳过，
        build.ninja 继续复用旧文件——其内部硬编码的仍是旧缓存绝对路径，ninja 随即 Stat 失败。
        判定规则：build.ninja 引用了 transforms 缓存、但路径不含当前 GRADLE_USER_HOME -> 整个 .cxx 删除，
        强制本次构建重新运行 CMake 配置。
    #>
    param([Parameter(Mandatory = $true)][string]$CurrentGradleUserHome)

    $normalizedHome = [System.IO.Path]::GetFullPath($CurrentGradleUserHome).TrimEnd('\')

    # 候选目录：node_modules 顶层包 + @scope 第二级包 + app 模块自身
    $pkgDirs = [System.Collections.Generic.List[string]]::new()
    $nmDir = Join-Path $script:MobileRoot 'node_modules'
    if (Test-Path -LiteralPath $nmDir) {
        foreach ($entry in (Get-ChildItem -LiteralPath $nmDir -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($entry.Name.StartsWith('@')) {
                foreach ($scoped in (Get-ChildItem -LiteralPath $entry.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                    $pkgDirs.Add($scoped.FullName)
                }
            }
            else {
                $pkgDirs.Add($entry.FullName)
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($script:AndroidDir)) {
        $pkgDirs.Add((Join-Path $script:AndroidDir 'app'))
    }

    $removed = 0
    foreach ($pkgDir in $pkgDirs) {
        $cxxDir = Join-Path $pkgDir 'android\.cxx'
        if (-not (Test-Path -LiteralPath $cxxDir)) { continue }

        # 取样一份 build.ninja（.cxx\<config>\<hash>\<abi>\build.ninja）
        $sample = Get-ChildItem -LiteralPath $cxxDir -Filter 'build.ninja' -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $sample) { continue }

        $content = Get-Content -LiteralPath $sample.FullName -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrEmpty($content)) { continue }

        # build.ninja 中路径以 / 分隔，统一为 \ 后比较
        $contentNorm = $content.Replace('/', '\')
        $referencesTransforms = $contentNorm.Contains('\transforms\')
        $referencesCurrentHome = $contentNorm.Contains($normalizedHome)
        if ((-not $referencesTransforms) -or $referencesCurrentHome) { continue }

        $pkgName = Split-Path -Leaf (Split-Path -Parent $cxxDir)
        Write-BuildWarn "检测到 $pkgName 的 CMake 缓存仍引用旧 Gradle 缓存路径，正在清理：$cxxDir"
        Remove-Item -LiteralPath $cxxDir -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $cxxDir)) {
            $removed++
        }
        else {
            Write-BuildWarn "  清理失败（可能被占用）：$cxxDir"
        }
    }

    if ($removed -gt 0) {
        Write-BuildInfo "已清理 $removed 个过期 CMake 构建目录（.cxx），本次构建将重新运行 CMake 配置（耗时数分钟）。"
    }
}

function Invoke-GradleAssembleRelease {
    <#
        执行 gradlew assembleRelease，并对 transforms 缓存损坏做自愈重试：
        构建输出中出现 immutable workspace "have been modified"（上次构建中断 /
        杀软扫描 / 磁盘错误导致的内容级损坏）时，自动定位损坏条目 → 停 daemon
        释放锁 → 删除 → 重试一次；重试仍失败才抛出。
    #>
    param([Parameter(Mandatory)][string]$Gradlew)

    # Gradle/javac 以 UTF-8 输出诊断，中文 Windows 控制台默认按 GBK 解码子进程输出
    # 会产生乱码并污染 Tee 捕获的日志；构建期间切换为 UTF-8 解码，
    # finally 恢复原值（无控制台宿主时静默跳过），与 Invoke-FlutterBuildApk 行为一致
    $prevConsoleOutputEncoding = $null
    try { $prevConsoleOutputEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

    try {
        $maxAttempts = 2
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            Push-Location $script:AndroidDir
            try {
                Write-BuildInfo "开始执行 gradlew assembleRelease --info...（第 $attempt/$maxAttempts 次）"
                & $Gradlew assembleRelease --info 2>&1 | Tee-Object -Variable buildLog | ForEach-Object {
                    $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
                    Write-Host $line
                    if ($null -ne $script:BuildLogWriter) { $script:BuildLogWriter.WriteLine($line) }
                }
                if ($LASTEXITCODE -eq 0) { return }

                $text = ($buildLog | Out-String)
                if ((-not (Test-GradleTransformCorruption -LogText $text)) -or ($attempt -eq $maxAttempts)) {
                    Write-BuildFailureHint -LogText $text
                    throw "Gradle 构建失败，退出码 $LASTEXITCODE。"
                }

                Write-BuildWarn "检测到 Gradle transforms 缓存损坏。常见诱因：上次构建被强制中断、杀毒软件扫描缓存、磁盘错误。"
                Repair-CorruptedGradleTransforms -LogText $text -Gradlew $Gradlew
                Write-BuildInfo "损坏缓存已自动清理，正在重试构建..."
            }
            finally {
                Pop-Location
            }
        }
    }
    finally {
        if ($null -ne $prevConsoleOutputEncoding) { try { [Console]::OutputEncoding = $prevConsoleOutputEncoding } catch { } }
    }
}
