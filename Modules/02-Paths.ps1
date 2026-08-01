#Requires -Version 5.1
#=============================================================================
# 02-Paths.ps1 - 路径检测与环境工具
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================

# =============================================================================
# PATH 检测（使用 where.exe，符合需求）
# =============================================================================

function Check-Path {
    <#
    .SYNOPSIS
        检测指定命令是否在当前会话 PATH 中可用。
    .OUTPUTS
        PSCustomObject: @{ Exists = bool; Path = string }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    $found = $null
    try {
        $found = (& where.exe $Name 2>$null) | Select-Object -First 1
    }
    catch {
        # where.exe 不可用时回退到 Get-Command
        try {
            $found = (Get-Command -Name $Name -ErrorAction Stop).Source
        }
        catch {
            $found = $null
        }
    }

    return [pscustomobject]@{
        Exists = -not [string]::IsNullOrWhiteSpace($found)
        Path   = $found
    }
}


# =============================================================================
# PATH 注入：仅在当前进程作用域设置环境变量，绝不触碰 User/Machine
# =============================================================================

function Add-PortablePath {
    <#
    .SYNOPSIS
        将目录注入当前进程 PATH 最前，并可同时设置 JAVA_HOME / ANDROID_HOME / ANDROID_SDK_ROOT。
    .DESCRIPTION
        使用 [Environment]::SetEnvironmentVariable 在 Process 作用域操作，
        避免修改系统或用户级环境变量。会先去重，避免 PATH 重复累积。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter()]
        [ValidateSet("JAVA_HOME", "ANDROID_HOME", "ANDROID_SDK_ROOT")]
        [string]$HomeVariable,

        [Parameter()]
        [string]$HomeValue
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        throw "Add-PortablePath: 目录不存在：$Directory"
    }

    $resolvedBin = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\')

    if ($HomeVariable -and $HomeValue) {
        if (-not (Test-Path -LiteralPath $HomeValue)) {
            throw "Add-PortablePath: $HomeVariable 指向的目录不存在：$HomeValue"
        }
        $resolvedHome = [System.IO.Path]::GetFullPath($HomeValue).TrimEnd('\')
        [System.Environment]::SetEnvironmentVariable(
            $HomeVariable,
            $resolvedHome,
            [System.EnvironmentVariableTarget]::Process
        )
    }

    $currentPath = [System.Environment]::GetEnvironmentVariable(
        "PATH",
        [System.EnvironmentVariableTarget]::Process
    )
    $parts = $currentPath -split ';' |
        Where-Object { $_ -and ($_ -ne $resolvedBin) } |
        ForEach-Object { $_.Trim() }

    [System.Environment]::SetEnvironmentVariable(
        "PATH",
        "$resolvedBin;$($parts -join ';')",
        [System.EnvironmentVariableTarget]::Process
    )
}

# =============================================================================
# 辅助：Java 版本号 / Gradle 路径转义 / 目录安全删除
# =============================================================================

function Get-ShortProjectId {
    <#
        生成项目短标识，用于 GRADLE_USER_HOME 等需要极短路径的目录名。
        项目名 <= 12 字符时直接使用；否则取前 8 字符 + 4 位 SHA1，保证确定性与可读性。
        （用 SHA1 而非 MD5：MD5.Create() 在启用 FIPS 策略的系统上会直接抛异常）
    #>
    $name = $script:ProjectName
    if ($name.Length -le 12) { return $name }
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hashBytes = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($name))
        $hash = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
        return ($name.Substring(0, 8) + '-' + $hash.Substring(0, 4))
    }
    finally {
        $sha1.Dispose()
    }
}

function Get-GlobalToolsRoot {
    <#
        返回全局共享工具根目录（默认 C:\APKTools，可由 config.json paths.globalToolsRoot 覆盖）。
        供导入方脚本（如 Menu.ps1）使用：模块的 $script: 变量对导入方不可见。
    #>
    return $script:GlobalToolsRoot
}

function Convert-ToGradlePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $Path.Replace('\', '\\').Replace(':', '\:')
}

function Remove-DirectoryInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AllowedRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $resolvedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $resolvedRoot = [System.IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\')
    $rootPrefix = "$resolvedRoot\"

    if (-not $resolvedPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clear a path outside the allowed root: $resolvedPath"
    }

    Write-BuildWarn "正在清理：$resolvedPath"
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force -ErrorAction SilentlyContinue
}

function Remove-DirectoryRobust {
    <#
        删除目录：优先 Remove-Item；遇到超长路径或残留锁导致失败时，
        回退 robocopy 镜像空目录法（对长路径最可靠）。返回是否删除成功。
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return $true
    }
    catch {
        $empty = Join-Path $env:TEMP ("empty-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        & robocopy $empty $Path /MIR /NJH /NJS /NP /NFL /NDL | Out-Null
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $empty -Force -ErrorAction SilentlyContinue
        return (-not (Test-Path -LiteralPath $Path))
    }
}
