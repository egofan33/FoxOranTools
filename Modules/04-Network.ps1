#Requires -Version 5.1
#=============================================================================
# 04-Network.ps1 - 下载、进度与解压
# BuildHelper 功能域分文件：由 BuildHelper.psm1 按序点源加载，共享模块 $script: 作用域。
# 请勿单独执行本文件。
#=============================================================================

function Expand-ArchiveRobust {
    <#
        使用 .NET ZipFile 解压，规避 Windows PowerShell 5.1 中
        Expand-Archive 对 Node.js 官方 zip 解压后为空目录的 bug。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Expand-ArchiveRobust: 压缩包不存在：$Path"
    }

    $resolvedZip = [System.IO.Path]::GetFullPath($Path)
    $resolvedDest = [System.IO.Path]::GetFullPath($DestinationPath)

    if (Test-Path -LiteralPath $resolvedDest) {
        if (-not $Force) {
            throw "Expand-ArchiveRobust: 目标目录已存在：$resolvedDest"
        }
        Remove-Item -LiteralPath $resolvedDest -Recurse -Force -ErrorAction Stop
    }

    New-Item -ItemType Directory -Path $resolvedDest -Force | Out-Null

    # 确保 ZipFile 可用（Windows PowerShell 5.1 需要手动加载）
    if (-not ("System.IO.Compression.ZipFile" -as [type])) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    }

    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($resolvedZip, $resolvedDest)
    }
    catch {
        throw "Expand-ArchiveRobust: 解压失败：$($_.Exception.Message)"
    }

    # 校验：目标目录不为空
    $items = Get-ChildItem -LiteralPath $resolvedDest -Force -ErrorAction SilentlyContinue
    if (-not $items) {
        throw "Expand-ArchiveRobust: 解压后目录为空：$resolvedDest"
    }
}

function Test-ZipArchiveIntegrity {
    <#
        解压前快速校验 zip 完整性：
        1. 文件头必须为 PK（排除代理返回的 HTML/JSON 错误页）；
        2. 能以 ZipArchive 打开并读取中央目录（排除被截断的文件）。
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $fullPath = [System.IO.Path]::GetFullPath($Path)

    try {
        $fs = [System.IO.File]::OpenRead($fullPath)
        try {
            $header = New-Object byte[] 2
            $read = $fs.Read($header, 0, 2)
            if ($read -lt 2 -or $header[0] -ne 0x50 -or $header[1] -ne 0x4B) {
                return $false
            }
        }
        finally {
            $fs.Dispose()
        }

        if (-not ("System.IO.Compression.ZipFile" -as [type])) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
        }

        $zip = [System.IO.Compression.ZipFile]::OpenRead($fullPath)
        try {
            return ($zip.Entries.Count -gt 0)
        }
        finally {
            $zip.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Download-FileWithProgress {
    <#
        使用 HttpWebRequest 流式下载文件，并实时显示 ASCII 进度条。
        返回下载完成的字节数，出错时抛出异常。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$TimeoutSec = $script:DownloadTimeoutSec
    )

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = $script:UserAgent
    $request.Timeout = $TimeoutSec * 1000
    $request.AllowAutoRedirect = $true
    $request.MaximumAutomaticRedirections = 5
    $request.Method = 'GET'
    # 传输停滞保护：连接建立后超过 2 分钟无数据传输即中止并进入重试（.NET 默认 300 秒过长）
    $request.ReadWriteTimeout = 120000

    $response = $request.GetResponse()
    $stream = $response.GetResponseStream()
    $fileStream = [System.IO.File]::Create($Destination)

    $total = $response.ContentLength
    # 256KB 缓冲：下载大文件（约 1GB 的 Flutter SDK）时 Read/Write 系统调用减少约 32 倍
    $bufferSize = 262144
    $buffer = New-Object byte[] $bufferSize
    $downloaded = [long]0
    $lastUpdate = [DateTime]::Now
    $lastDownloaded = [long]0
    $fileName = Split-Path -Leaf $Destination

    try {
        while ($true) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $fileStream.Write($buffer, 0, $read)
            $downloaded += $read

            $now = [DateTime]::Now
            $elapsed = ($now - $lastUpdate).TotalSeconds
            if ($elapsed -ge 0.5) {
                $speed = ($downloaded - $lastDownloaded) / $elapsed
                Write-DownloadProgress -Downloaded $downloaded -Total $total -SpeedBytesPerSecond $speed -FileName $fileName
                $lastUpdate = $now
                $lastDownloaded = $downloaded
            }
        }

        # 连接中断时 Read 返回 0 与正常结束无法区分，必须比对 ContentLength，
        # 否则被截断的文件会被误判为下载成功（典型症状：解压时报"找不到中央目录结尾记录"）
        if ($total -gt 0 -and $downloaded -ne $total) {
            throw "下载不完整：已接收 $(Format-FileSize -Bytes $downloaded)，应为 $(Format-FileSize -Bytes $total)（连接中断或被截断）。"
        }

        # 最终状态
        Write-DownloadProgress -Downloaded $downloaded -Total $total -SpeedBytesPerSecond 0 -FileName $fileName
        try {
            [System.Console]::WriteLine()
        }
        catch {
            Write-Host ''
        }
    }
    finally {
        $fileStream.Dispose()
        $stream.Dispose()
        $response.Dispose()
    }

    return $downloaded
}

function Download-File {
    <#
    .SYNOPSIS
        下载文件。原始 URL 失败/超时后，自动在 URL 前拼接 gh-proxy.com 重试。
        下载过程中会显示 ASCII 进度条，便于判断下载速度/连接是否畅通。
        若提供了 ExpectedSha256，下载完成后会校验文件哈希；若下载失败，会删除残留文件。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$MaxRetries = $script:MaxRetries,
        [int]$TimeoutSec = $script:DownloadTimeoutSec,
        [string]$ExpectedSha256 = $null
    )

    $directory = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    # 清理上次中断残留的下载文件。File.Create 对已存在文件虽会覆盖，但被占用
    # （如旧下载进程仍在后台运行）时会直接失败且重试无意义。
    # 短暂锁定（杀软/索引扫描）等待后重试一次删除；仍被占用则给出明确处置提示。
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Destination) {
            Start-Sleep -Seconds 2
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $Destination) {
            throw @"
下载目标文件正被其他进程占用：$Destination
可能是此前中断的下载进程仍在后台运行。
处理方法：等待该进程结束（或在任务管理器中结束对应的 powershell 进程）后重试；也可手动删除该文件。
"@
        }
    }

    $candidateUrls = @($Url)
    if (-not [string]::IsNullOrEmpty($script:ProxyPrefix) -and -not $Url.StartsWith($script:ProxyPrefix)) {
        $candidateUrls += "$($script:ProxyPrefix)$Url"
    }
    $lastError = $null

    for ($i = 0; $i -lt $MaxRetries; $i++) {
        $currentUrl = $candidateUrls[$i % $candidateUrls.Count]
        Write-BuildInfo "下载尝试 $($i + 1)/$MaxRetries`: $currentUrl"

        try {
            $null = Download-FileWithProgress -Url $currentUrl -Destination $Destination -TimeoutSec $TimeoutSec

            if (-not (Test-Path -LiteralPath $Destination)) {
                throw "下载完成但文件不存在：$Destination"
            }

            $fileSize = (Get-Item -LiteralPath $Destination).Length
            if ($fileSize -eq 0) {
                throw "下载文件大小为 0：$Destination"
            }

            if ($ExpectedSha256) {
                Write-BuildInfo '正在校验 SHA256...'
                $actualHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
                if ($actualHash -ne $ExpectedSha256.ToUpper()) {
                    throw "SHA256 校验失败：期望 $ExpectedSha256，实际 $actualHash"
                }
                Write-BuildInfo 'SHA256 校验通过。'
            }

            return
        }
        catch {
            $lastError = $_
            Write-BuildWarn "下载失败：$($_.Exception.Message)"
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            }
            # 如果上一行是进度条，确保换行，避免后续日志与进度条粘在一起
            try {
                [System.Console]::WriteLine()
            }
            catch {
                Write-Host ''
            }
        }
    }

    throw "Download-File: 无法下载 $Url，已重试 $MaxRetries 次。最后一次错误：$lastError"
}
