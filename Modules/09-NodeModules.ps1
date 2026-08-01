#Requires -Version 5.1
#=============================================================================
# 09-NodeModules.ps1 - node_modules 安装与链接修复
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================

function Get-PackageManager {
    <#
        根据锁文件选择包管理器：yarn.lock -> yarn，pnpm-lock.yaml -> pnpm，否则 npm。
    #>
    $yarnLock = Join-Path $script:MobileRoot "yarn.lock"
    $pnpmLock = Join-Path $script:MobileRoot "pnpm-lock.yaml"

    if (Test-Path -LiteralPath $yarnLock) { return 'yarn' }
    if (Test-Path -LiteralPath $pnpmLock) { return 'pnpm' }
    return 'npm'
}

function Install-NodeModules {
    <#
        按锁文件选择包管理器安装依赖。
    #>
    $pm = Get-PackageManager
    Write-BuildInfo "使用包管理器：$pm"

    Push-Location $script:MobileRoot
    try {
        switch ($pm) {
            'yarn' { & yarn install }
            'pnpm' { & pnpm install }
            default { & npm install }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "$pm install 失败，退出码 $LASTEXITCODE。"
        }
    }
    finally {
        Pop-Location
    }
}

function Get-WorkspacePackageMap {
    <#
        解析 package.json 的 workspaces 配置，返回 "包名 -> 当前项目内目录" 映射。
        依次检查 MobileRoot 与 ProjectRoot（去重），找到第一份含 workspaces 的配置即返回。
    #>
    $roots = @($script:MobileRoot, $script:ProjectRoot) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique

    foreach ($root in $roots) {
        $pkgPath = Join-Path $root "package.json"
        if (-not (Test-Path -LiteralPath $pkgPath)) { continue }

        $json = $null
        try {
            $json = Get-Content -LiteralPath $pkgPath -Raw -ErrorAction Stop | ConvertFrom-Json
        }
        catch { continue }

        $patterns = @()
        if ($json.workspaces) {
            if ($json.workspaces -is [array]) { $patterns = @($json.workspaces) }
            elseif ($json.workspaces -is [string]) { $patterns = @($json.workspaces) }
            elseif ($json.workspaces.packages) { $patterns = @($json.workspaces.packages) }
        }
        if ($patterns.Count -eq 0) { continue }

        $map = @{}
        foreach ($pattern in $patterns) {
            if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
            if ($pattern.StartsWith('!')) { continue }

            # 展开 glob：支持 "packages/*"、"packages/**" 与具体目录 "packages/foo"
            $dirs = @()
            $clean = $pattern.Replace('/', '\').TrimEnd('\')
            if ($clean.EndsWith('\**')) {
                $base = Join-Path $root $clean.Substring(0, $clean.Length - 3)
                if (Test-Path -LiteralPath $base) {
                    $dirs = @(Get-ChildItem -LiteralPath $base -Directory -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'package.json') })
                }
            }
            elseif ($clean.EndsWith('\*')) {
                $base = Join-Path $root $clean.Substring(0, $clean.Length - 2)
                if (Test-Path -LiteralPath $base) {
                    $dirs = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)
                }
            }
            else {
                $dir = Join-Path $root $clean
                if (Test-Path -LiteralPath $dir) { $dirs = @(Get-Item -LiteralPath $dir) }
            }

            foreach ($dir in $dirs) {
                $pkgJsonFile = Join-Path $dir.FullName 'package.json'
                if (-not (Test-Path -LiteralPath $pkgJsonFile)) { continue }
                try {
                    $pkgJson = Get-Content -LiteralPath $pkgJsonFile -Raw -ErrorAction Stop | ConvertFrom-Json
                    if ($pkgJson.name -and -not $map.ContainsKey($pkgJson.name)) {
                        $map[$pkgJson.name] = $dir.FullName
                    }
                }
                catch { }
            }
        }

        if ($map.Count -gt 0) { return $map }
    }

    return @{}
}

function Repair-NodeModulesJunctions {
    <#
        node_modules 链接健康预检。
        项目目录被整体移动/重命名后，npm/yarn 生成的 workspace junction 仍指向旧的绝对路径，
        Metro/Gradle 会以非常隐晦的方式报错。本函数扫描 node_modules 中的 junction/符号链接：
          1. workspace 包链接：目标缺失，或指向的路径与当前 workspace 目录不一致 -> 重建
          2. 其他悬空链接（目标已不存在）-> 删除，并标记需要重新安装依赖
        返回 PSCustomObject：@{ Repaired; Removed; NeedsReinstall }
    #>
    $result = [pscustomobject]@{ Repaired = 0; Removed = 0; NeedsReinstall = $false }

    $nmRoots = @($script:MobileRoot, $script:ProjectRoot) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique |
        ForEach-Object { Join-Path $_ 'node_modules' } |
        Where-Object { Test-Path -LiteralPath $_ }
    if (-not $nmRoots) { return $result }

    $workspaceMap = Get-WorkspacePackageMap
    $expectedTargets = @{}
    foreach ($name in $workspaceMap.Keys) {
        $expectedTargets[$name] = [System.IO.Path]::GetFullPath($workspaceMap[$name]).TrimEnd('\')
    }

    foreach ($nmRoot in $nmRoots) {
        # 收集候选：顶层目录 + @scope 下第二级目录
        $candidates = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in (Get-ChildItem -LiteralPath $nmRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($entry.Name -in @('.bin', '.cache')) { continue }
            if ($entry.Name.StartsWith('@')) {
                foreach ($scoped in (Get-ChildItem -LiteralPath $entry.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                    $candidates.Add([pscustomobject]@{ Name = "$($entry.Name)/$($scoped.Name)"; Item = $scoped })
                }
            }
            else {
                $candidates.Add([pscustomobject]@{ Name = $entry.Name; Item = $entry })
            }
        }

        foreach ($candidate in $candidates) {
            $item = $candidate.Item
            # 只处理 reparse point（junction / symbolic link），普通目录跳过
            if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }

            $target = $null
            try { $target = @($item.Target)[0] } catch { }
            if ([string]::IsNullOrWhiteSpace($target)) { continue }

            $targetFull = [System.IO.Path]::GetFullPath($target).TrimEnd('\')
            $targetExists = Test-Path -LiteralPath $targetFull

            $expected = $null
            if ($expectedTargets.ContainsKey($candidate.Name)) { $expected = $expectedTargets[$candidate.Name] }

            if ($expected) {
                # workspace 包：目标缺失或指向别处（典型：项目被移动/重命名后仍指向旧路径）
                if ((-not $targetExists) -or ($targetFull -ne $expected)) {
                    Write-BuildWarn "workspace 链接指向异常：node_modules\$($candidate.Name)"
                    Write-BuildWarn "  当前指向：$targetFull$(if (-not $targetExists) { '（已不存在）' })"
                    Write-BuildWarn "  期望指向：$expected"
                    try {
                        [System.IO.Directory]::Delete($item.FullName, $false)
                        New-Item -ItemType Junction -Path $item.FullName -Target $expected -ErrorAction Stop | Out-Null
                        $result.Repaired++
                        Write-BuildInfo "  已重建链接：node_modules\$($candidate.Name) -> $expected"
                    }
                    catch {
                        Write-BuildWarn "  重建失败：$($_.Exception.Message)"
                        $result.NeedsReinstall = $true
                    }
                }
            }
            elseif (-not $targetExists) {
                # 非 workspace 悬空链接：删除并标记需要重新安装
                Write-BuildWarn "检测到悬空链接：node_modules\$($candidate.Name) -> $targetFull（目标不存在，已移除）"
                try {
                    [System.IO.Directory]::Delete($item.FullName, $false)
                    $result.Removed++
                    $result.NeedsReinstall = $true
                }
                catch {
                    Write-BuildWarn "  移除失败：$($_.Exception.Message)"
                }
            }
        }
    }

    if (($result.Repaired -gt 0) -or ($result.Removed -gt 0)) {
        Write-BuildInfo "node_modules 链接预检完成：重建 $($result.Repaired) 个，移除悬空 $($result.Removed) 个。"
    }
    return $result
}

function Ensure-NodeModules {
    <#
        确保 Node 依赖就绪（Gradle 构建依赖 node_modules：codegen / hermes / RN gradle plugin）。
        - 无 package.json：视为纯原生 Android 项目，跳过。
        - node_modules 缺失，或 package.json/锁文件比 node_modules 新：执行安装。
    #>
    if ($script:IsFlutterProject) {
        Write-BuildInfo "Flutter 项目，跳过 Node 依赖安装。"
        return
    }

    $packageJson = Join-Path $script:MobileRoot "package.json"
    if (-not (Test-Path -LiteralPath $packageJson)) {
        Write-BuildInfo "未检测到 package.json，跳过 Node 依赖安装（纯原生 Android 项目）。"
        return
    }

    $nodeModulesDir = Join-Path $script:MobileRoot "node_modules"
    $reason = $null

    if (-not (Test-Path -LiteralPath $nodeModulesDir)) {
        $reason = "未检测到 node_modules"
    }
    else {
        # 预检 node_modules 中的 junction/符号链接：项目目录被移动或重命名后，
        # npm/yarn 生成的 workspace 链接仍指向旧绝对路径，需重建或清理
        $junctionCheck = Repair-NodeModulesJunctions
        if ($junctionCheck.NeedsReinstall) {
            $reason = "node_modules 中存在已失效的链接"
        }

        $nodeModulesTime = (Get-Item -LiteralPath $nodeModulesDir).LastWriteTime
        $newestChange = @('package.json', 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml') |
            ForEach-Object { Join-Path $script:MobileRoot $_ } |
            Where-Object { Test-Path -LiteralPath $_ } |
            ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTime } |
            Sort-Object -Descending |
            Select-Object -First 1
        if ($newestChange -gt $nodeModulesTime) {
            $reason = "package.json 或锁文件有更新"
        }
    }

    if ($reason) {
        Write-BuildInfo "$reason，正在安装 Node 依赖..."
        Install-NodeModules
    }
    else {
        Write-BuildInfo "node_modules 已就绪，跳过依赖安装。"
    }
}
