#Requires -Version 5.1
#=============================================================================
# 01-Logging.ps1 - 日志与进度输出
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================

# =============================================================================
# 彩色日志函数
# =============================================================================

function Write-BuildInfo {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-BuildWarn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-BuildError {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}


# =============================================================================
# 通用下载（带 GitHub Releases 自动换源重试）
# =============================================================================

function Format-FileSize {
    <#
        将字节数转换为人类可读字符串（B / KB / MB / GB / TB）。
    #>
    param(
        [Parameter(Mandatory = $true)][long]$Bytes
    )
    $sizes = @('B', 'KB', 'MB', 'GB', 'TB')
    $index = 0
    $size = [double]$Bytes
    while ($size -ge 1024 -and $index -lt $sizes.Count - 1) {
        $size /= 1024
        $index++
    }
    return '{0:F2} {1}' -f $size, $sizes[$index]
}

function Write-DownloadProgress {
    <#
        在控制台单行输出 ASCII 下载进度条，使用回车符覆盖上一行。
        适合在 CMD / PowerShell 中显示大文件下载进度，不残留 PowerShell 进度条。
    #>
    param(
        [Parameter(Mandatory = $true)][long]$Downloaded,
        [Parameter(Mandatory = $true)][long]$Total,
        [Parameter(Mandatory = $true)][double]$SpeedBytesPerSecond,
        [string]$FileName = ''
    )

    $barWidth = 30
    $downloadedStr = Format-FileSize -Bytes $Downloaded
    $speedStr = (Format-FileSize -Bytes $SpeedBytesPerSecond) + '/s'

    if ($Total -gt 0) {
        $percent = [math]::Floor(($Downloaded / $Total) * 100)
        $filled = [math]::Floor($barWidth * $percent / 100)
        $bar = ('#' * $filled) + ('-' * ($barWidth - $filled))
        $totalStr = Format-FileSize -Bytes $Total
        $status = "[$bar] $percent%  $downloadedStr / $totalStr  $speedStr"
    }
    else {
        # 总量未知（chunked / 无 Content-Length）：滑动块表示传输活动中，
        # 不展示伪造的 0% 与空进度条，避免误以为卡死
        $blockSize = 6
        $track = $barWidth - $blockSize
        $pos = [int]([DateTime]::Now.Ticks / 3000000) % ($track + 1)
        $bar = ('-' * $pos) + ('#' * $blockSize) + ('-' * ($track - $pos))
        $status = "[$bar]  $downloadedStr / 未知  $speedStr"
    }
    if ($FileName) {
        $status = "$FileName  $status"
    }

    # 截断到控制台宽度，避免换行导致重影
    $maxWidth = 0
    try {
        $maxWidth = [System.Console]::WindowWidth
    }
    catch {
        $maxWidth = 0
    }
    if ($maxWidth -gt 0 -and $status.Length -gt $maxWidth) {
        $status = $status.Substring(0, $maxWidth)
    }

    try {
        [System.Console]::Write("`r$status")
    }
    catch {
        # 非交互式环境（无控制台句柄）回退到 Write-Host
        Write-Host $status
    }
}
