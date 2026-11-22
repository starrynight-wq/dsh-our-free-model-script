#Requires -Version 5.1
<#
.SYNOPSIS
    Our Free Model（dsh-our-free-model）一键安装 / 卸载脚本（Windows + 已安装 DeepSeek Harness）。

.DESCRIPTION
    本脚本做四件事：
      1. 从 GitHub 官方 Release 找到最新正式版，并下载插件包 dsh-our-free-model-<版本>.tgz；
      2. 用发布页的 SHA256SUMS 校验安装包完整性（SHA-256）；
      3. 调用 DeepSeek Harness 自带的 dsh CLI（使用其内置 pnpm）把插件安装进指定 profile，
         与「设置 → 插件 → 添加插件」走的是同一条官方安装路径；
      4. 安装后检查 profile 清单与已安装文件，并给出重启与使用指引。

    脚本不会修改 DSH 内核，也不要求系统安装 Node.js / pnpm：桌面端自带 dsh CLI 与 pnpm。
    若系统 PATH 中已有 `dsh` 命令（例如通过 npm 安装的 CLI），脚本会优先使用它。

.PARAMETER Profile
    DSH profile 名称。默认：发现桌面端时用 desktop；否则取环境变量 DSH_PROFILE；
    再否则取磁盘上唯一的 profile，最后退回 web。

.PARAMETER DshHome
    DSH 数据目录。默认：环境变量 DSH_HOME，否则 %USERPROFILE%\.dsh。

.PARAMETER Version
    指定版本，例如 2.8.9。默认取 GitHub 最新正式版。

.PARAMETER Tarball
    使用本地已下载的 .tgz 插件包（离线或手动下载时使用），仍会尽量做 SHA-256 校验。

.PARAMETER AppDir
    DeepSeek Harness 桌面端安装目录。自动探测失败时手动指定（目录内应有
    resources\runtime\cli\bin\dsh.cmd）。

.PARAMETER Uninstall
    卸载插件（保留插件数据目录，便于以后再次安装）。

.PARAMETER Force
    已安装相同版本时强制重装（版本不同时总是升级/降级到目标版本）。

.PARAMETER SkipChecksum
    跳过 SHA-256 校验。不安全，仅在确认来源可信时使用。

.PARAMETER DryRun
    只检测环境并打印将要执行的步骤，不修改任何文件。

.EXAMPLE
    # 最常用：直接双击「一键安装 Our Free Model.cmd」
    # 或者手动执行（只检查环境）：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install-our-free-model.ps1 -DryRun

.EXAMPLE
    # 指定官方版本安装：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install-our-free-model.ps1 -Version 2.8.9

.EXAMPLE
    # 离线安装（先自行从 GitHub Releases 下载 .tgz）：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install-our-free-model.ps1 -Tarball .\dsh-our-free-model-2.8.9.tgz

.EXAMPLE
    # 卸载：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install-our-free-model.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Profile = '',
    [string]$DshHome = '',
    [string]$Version = '',
    [string]$Tarball = '',
    [string]$AppDir = '',
    [switch]$Uninstall,
    [switch]$Force,
    [switch]$SkipChecksum,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 常量与全局状态
# ---------------------------------------------------------------------------
$script:RepoSlug = 'Ebony-Vinyl/dsh-our-free-model'
$script:PackageName = 'dsh-our-free-model'
$script:ScopedPackageName = '@ebony-vinyl/dsh-our-free-model'

$script:DshHomePath = $null
$script:ProfileName = $null
$script:ProfileDir = $null
$script:CliPath = $null
$script:CliKind = $null
$script:AppDirPath = $null
$script:AppRunning = $false
$script:TranscriptPath = $null
$script:TranscriptStarted = $false

# ---------------------------------------------------------------------------
# 输出辅助
# ---------------------------------------------------------------------------
function Write-Banner {
    Write-Host ''
    Write-Host '  ================================================================' -ForegroundColor DarkCyan
    Write-Host '   Our Free Model  ·  DeepSeek Harness 插件一键安装 / 卸载' -ForegroundColor Cyan
    Write-Host '   ================================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host ("==> " + $Text) -ForegroundColor Cyan
}

function Write-Detail([string]$Text) {
    Write-Host ("    " + $Text) -ForegroundColor Gray
}

function Write-Ok([string]$Text) {
    Write-Host ("[成功] " + $Text) -ForegroundColor Green
}

function Write-Note([string]$Text) {
    Write-Host ("[提示] " + $Text) -ForegroundColor DarkGray
}

function Write-WarnMsg([string]$Text) {
    Write-Host ("[警告] " + $Text) -ForegroundColor Yellow
}

function Write-FailMsg([string]$Text) {
    Write-Host ''
    Write-Host ("[失败] " + $Text) -ForegroundColor Red
}

function Stop-Script([string]$Text) {
    Write-FailMsg $Text
    exit 1
}

# ---------------------------------------------------------------------------
# 通用辅助
# ---------------------------------------------------------------------------
function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Resolve-ExistingPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if (-not (Test-Path -LiteralPath $expanded)) { return $null }
    return (Resolve-Path -LiteralPath $expanded).Path
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TarPath {
    $systemTar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path -LiteralPath $systemTar) { return $systemTar }
    $command = Get-Command -Name 'tar' -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' } | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    return $null
}

# ---------------------------------------------------------------------------
# 探测：DeepSeek Harness 桌面端目录、PATH 中的 dsh、profile
# ---------------------------------------------------------------------------
function Test-DesktopAppDir([string]$Dir) {
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    $shim = Join-Path $Dir 'resources\runtime\cli\bin\dsh.cmd'
    return (Test-Path -LiteralPath $shim)
}

function Resolve-DesktopAppDir([string]$Hint) {
    if (-not [string]::IsNullOrWhiteSpace($Hint)) {
        $resolved = Resolve-ExistingPath $Hint
        if ($null -eq $resolved -or -not (Test-DesktopAppDir $resolved)) {
            Stop-Script ("-AppDir 指定的目录不是有效的 DeepSeek Harness 安装目录（应包含 resources\runtime\cli\bin\dsh.cmd）：" + $Hint)
        }
        return $resolved
    }

    # 1) 正在运行的桌面端进程
    try {
        foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
            $exePath = $null
            try { $exePath = $process.Path } catch { $exePath = $null }
            if ([string]::IsNullOrWhiteSpace($exePath)) { continue }
            $candidate = Split-Path -Parent $exePath
            if ($candidate -and (Test-DesktopAppDir $candidate)) { return (Get-Item -LiteralPath $candidate).FullName }
        }
    } catch {
        # 忽略无法读取路径的进程
    }

    # 2) 卸载注册表项
    $candidates = New-Object System.Collections.Generic.List[string]
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            $displayName = [string](Get-PropertyValue $props 'DisplayName')
            if ($displayName -notlike '*DeepSeek Harness*') { continue }
            $installLocation = [string](Get-PropertyValue $props 'InstallLocation')
            if ($installLocation) { $candidates.Add($installLocation) }
            $displayIcon = [string](Get-PropertyValue $props 'DisplayIcon')
            if ($displayIcon) {
                $iconPath = ($displayIcon -replace ',\d+$', '').Trim('"')
                if ($iconPath) { $candidates.Add((Split-Path -Parent $iconPath)) }
            }
            $uninstallString = [string](Get-PropertyValue $props 'UninstallString')
            if ($uninstallString) {
                if ($uninstallString -match '^"([^"]+)"') {
                    $candidates.Add((Split-Path -Parent $Matches[1]))
                } else {
                    $first = ($uninstallString -split '\s+')[0]
                    if ($first) { $candidates.Add((Split-Path -Parent $first)) }
                }
            }
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-DesktopAppDir $candidate) { return (Get-Item -LiteralPath $candidate).FullName }
    }

    # 3) 常见默认目录
    $common = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) { $common.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness')) }
    if ($env:ProgramFiles) { $common.Add((Join-Path $env:ProgramFiles 'DeepSeek Harness')) }
    if (${env:ProgramFiles(x86)}) { $common.Add((Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness')) }
    foreach ($candidate in $common) {
        if (Test-DesktopAppDir $candidate) { return (Get-Item -LiteralPath $candidate).FullName }
    }

    return $null
}

function Get-PathDsh {
    $commands = @(Get-Command -Name 'dsh' -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        if ($command.CommandType -ne 'Application') { continue }
        if ([string]::IsNullOrWhiteSpace($command.Source)) { continue }
        if (-not (Test-Path -LiteralPath $command.Source)) { continue }
        return $command.Source
    }
    return $null
}

function Test-AppRunning([string]$AppDir) {
    if ([string]::IsNullOrWhiteSpace($AppDir)) { return $false }
    $expectedExe = Join-Path $AppDir 'DeepSeek Harness.exe'
    try {
        foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
            $exePath = $null
            try { $exePath = $process.Path } catch { $exePath = $null }
            if ([string]::IsNullOrWhiteSpace($exePath)) { continue }
            if ($exePath -ieq $expectedExe) { return $true }
        }
    } catch {
        return $false
    }
    return $false
}

# ---------------------------------------------------------------------------
# 环境解析
# ---------------------------------------------------------------------------
function Resolve-Environment {
    # DSH 数据目录
    $rawHome = $DshHome
    if ([string]::IsNullOrWhiteSpace($rawHome)) {
        if ($env:DSH_HOME) { $rawHome = $env:DSH_HOME }
        else { $rawHome = Join-Path $env:USERPROFILE '.dsh' }
    }
    $expandedHome = [Environment]::ExpandEnvironmentVariables($rawHome.Trim().Trim('"'))
    $script:DshHomePath = [System.IO.Path]::GetFullPath($expandedHome)

    # 桌面端与 dsh CLI
    $script:AppDirPath = Resolve-DesktopAppDir $AppDir
    $pathDsh = Get-PathDsh

    # profile 名称
    $profileName = $Profile
    if ([string]::IsNullOrWhiteSpace($profileName)) {
        $profilesRoot = Join-Path $script:DshHomePath 'profiles'
        $existingProfiles = @()
        if (Test-Path -LiteralPath $profilesRoot) {
            $existingProfiles = @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        }
        if ($env:DSH_PROFILE) {
            $profileName = $env:DSH_PROFILE
        } elseif ($null -ne $script:AppDirPath) {
            # 桌面端默认 profile 为 desktop；若该 home 里明显是别的 profile，则尊重磁盘现状
            if ($existingProfiles -contains 'desktop' -or $existingProfiles.Count -eq 0) { $profileName = 'desktop' }
            elseif ($existingProfiles.Count -eq 1) { $profileName = $existingProfiles[0] }
            elseif ($existingProfiles -contains 'web') { $profileName = 'web' }
            else { $profileName = 'desktop' }
        } elseif ($existingProfiles.Count -eq 1) {
            $profileName = $existingProfiles[0]
        } elseif ($existingProfiles -contains 'desktop') {
            $profileName = 'desktop'
        } elseif ($existingProfiles -contains 'web') {
            $profileName = 'web'
        } else {
            $profileName = 'web'
        }
    }
    $profileName = $profileName.Trim()
    if ($profileName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        Stop-Script ("profile 名称不合法（只允许字母、数字、点、下划线、连字符）：" + $profileName)
    }
    $script:ProfileName = $profileName
    $script:ProfileDir = Join-Path (Join-Path $script:DshHomePath 'profiles') $script:ProfileName

    # 选择 CLI
    if ($script:ProfileName -ieq 'desktop') {
        if ($null -eq $script:AppDirPath) {
            Stop-Script ("profile「desktop」由 DeepSeek Harness 桌面端管理，但没有找到桌面端安装目录。" +
                "请先启动一次桌面端，或用 -AppDir 指定安装目录（目录内应有 resources\runtime\cli\bin\dsh.cmd）。")
        }
        $script:CliPath = Join-Path $script:AppDirPath 'resources\runtime\cli\bin\dsh.cmd'
        $script:CliKind = '桌面端内置 dsh CLI'
    } elseif ($null -ne $pathDsh) {
        $script:CliPath = $pathDsh
        $script:CliKind = 'PATH 中的 dsh CLI'
    } elseif ($null -ne $script:AppDirPath) {
        $script:CliPath = Join-Path $script:AppDirPath 'resources\runtime\cli\bin\dsh.cmd'
        $script:CliKind = '桌面端内置 dsh CLI'
    } else {
        Stop-Script ("没有找到 DeepSeek Harness：PATH 中没有 dsh 命令，也没有探测到桌面端安装目录。" +
            "请确认已安装并至少启动过一次，或用 -AppDir 指定安装目录。")
    }
    if (-not (Test-Path -LiteralPath $script:CliPath)) {
        Stop-Script ("找不到 dsh CLI：" + $script:CliPath)
    }

    # 数据目录 / profile 目录
    if (-not (Test-Path -LiteralPath $script:DshHomePath)) {
        if ($script:ProfileName -ieq 'desktop') {
            Stop-Script ("DSH 数据目录不存在：" + $script:DshHomePath +
                "。请先启动一次 DeepSeek Harness 桌面端，再运行本脚本。")
        }
        if ($DryRun) {
            Write-WarnMsg ("DSH 数据目录尚不存在：" + $script:DshHomePath + "（实际运行时会创建）。")
        } else {
            Ensure-Directory $script:DshHomePath
        }
    }

    # 桌面端 profile 必须由应用先初始化
    if ($script:ProfileName -ieq 'desktop' -and -not (Test-Path -LiteralPath (Join-Path $script:ProfileDir 'package.json'))) {
        Stop-Script ("桌面端 profile 尚未初始化：" + $script:ProfileDir +
            "。请先启动一次 DeepSeek Harness 桌面端，完全退出后再运行本脚本。")
    }

    # 桌面端运行状态（影响重启提示）
    $script:AppRunning = Test-AppRunning $script:AppDirPath

    # 环境摘要
    Write-Step '环境检测'
    Write-Detail ("DSH 数据目录：" + $script:DshHomePath)
    Write-Detail ("目标 profile：" + $script:ProfileName)
    Write-Detail ("profile 目录：" + $script:ProfileDir)
    Write-Detail ("dsh CLI：" + $script:CliPath)
    Write-Detail ("CLI 来源：" + $script:CliKind)
    if ($script:AppDirPath) {
        Write-Detail ("桌面端目录：" + $script:AppDirPath)
        if ($script:AppRunning) { Write-Detail '桌面端状态：正在运行（安装后需完全退出并重新启动）' }
        else { Write-Detail '桌面端状态：未运行' }
    }
    if ($script:ProfileName -ieq 'desktop' -and -not $script:AppRunning) {
        Write-Note '提示：桌面端未运行，安装完成后直接启动即可。'
    }

    # 非桌面 profile 不存在时，让 dsh CLI 初始化它
    if (-not (Test-Path -LiteralPath (Join-Path $script:ProfileDir 'package.json'))) {
        if ($DryRun) {
            Write-WarnMsg ("profile 尚未初始化：" + $script:ProfileDir + "（实际运行时将自动创建）。")
        } else {
            Write-Step ("初始化 profile「" + $script:ProfileName + "」...")
            $code = Invoke-DshCli -Arguments @('plugin', '--profile', $script:ProfileName, 'version-exemptions') -Quiet
            if ($code -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $script:ProfileDir 'package.json'))) {
                Stop-Script ("初始化 profile 失败（退出码 " + $code + "）。")
            }
            Write-Ok ("profile 已创建：" + $script:ProfileDir)
        }
    }
}

# ---------------------------------------------------------------------------
# 调用 dsh CLI
# ---------------------------------------------------------------------------
function Invoke-DshCli([string[]]$Arguments, [switch]$Quiet) {
    $env:DSH_HOME = $script:DshHomePath
    if (-not $Quiet) {
        $display = foreach ($argument in $Arguments) {
            if ($argument -match '\s') { '"' + $argument + '"' } else { $argument }
        }
        Write-Detail ("执行：" + $script:CliPath + ' ' + ($display -join ' '))
    }
    $captured = $null
    if ($Quiet) {
        $captured = & $script:CliPath @Arguments 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0 -and $null -ne $captured) {
            foreach ($line in @($captured)) { Write-Detail ([string]$line) }
        }
        return $code
    }
    # 直接转发到控制台（不走管道输出流），避免把 pnpm 输出当成函数返回值
    & $script:CliPath @Arguments | Out-Host
    $code = $LASTEXITCODE
    return $code
}

# ---------------------------------------------------------------------------
# profile / 安装状态读取
# ---------------------------------------------------------------------------
function Read-ProfileManifest {
    $manifestPath = Join-Path $script:ProfileDir 'package.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $null }
    $text = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
    try {
        return ($text | ConvertFrom-Json)
    } catch {
        Stop-Script ("profile 的 package.json 不是有效 JSON：" + $manifestPath)
    }
}

function Get-BundleList($Manifest) {
    $dsh = Get-PropertyValue $Manifest 'dsh'
    $profileSection = Get-PropertyValue $dsh 'profile'
    $bundles = Get-PropertyValue $profileSection 'bundles'
    if ($null -eq $bundles) { return @() }
    return @($bundles)
}

function Get-InstalledPackageDir {
    return (Join-Path (Join-Path $script:ProfileDir 'node_modules') $script:PackageName)
}

function Get-InstalledVersion {
    $packageJson = Join-Path (Get-InstalledPackageDir) 'package.json'
    if (-not (Test-Path -LiteralPath $packageJson)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($packageJson, [System.Text.Encoding]::UTF8)
        $package = $text | ConvertFrom-Json
        return [string](Get-PropertyValue $package 'version')
    } catch {
        return $null
    }
}

function Get-InstallProblems([string]$ExpectedVersion) {
    $problems = New-Object System.Collections.Generic.List[string]
    $manifest = Read-ProfileManifest
    if ($null -eq $manifest) {
        $problems.Add(("找不到 profile 清单：" + (Join-Path $script:ProfileDir 'package.json')))
        return ,$problems
    }
    $dependencies = Get-PropertyValue $manifest 'dependencies'
    if ($null -eq (Get-PropertyValue $dependencies $script:PackageName)) {
        $problems.Add(("package.json 的 dependencies 中没有 " + $script:PackageName))
    }
    $bundles = Get-BundleList $manifest
    if (-not ($bundles -contains $script:PackageName)) {
        $problems.Add(("dsh.profile.bundles 中没有 " + $script:PackageName))
    }
    $installed = Get-InstalledVersion
    if ([string]::IsNullOrWhiteSpace($installed)) {
        $problems.Add(("未找到已安装目录 node_modules\" + $script:PackageName))
    } elseif (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and $installed -ne $ExpectedVersion) {
        $problems.Add(("已安装版本 " + $installed + " 与目标版本 " + $ExpectedVersion + " 不一致"))
    }
    $packageDir = Get-InstalledPackageDir
    $requiredFiles = @('index.js', 'client.js', 'cordis.patch.yml', 'vendor\magpie\engine.json')
    foreach ($relative in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageDir $relative))) {
            $problems.Add(("缺少插件文件：" + $relative))
        }
    }
    return ,$problems
}

# ---------------------------------------------------------------------------
# 网络：版本查询、下载、校验
# ---------------------------------------------------------------------------
function Get-LatestRelease {
    $uri = "https://api.github.com/repos/$($script:RepoSlug)/releases?per_page=30"
    $headers = @{
        'User-Agent' = 'dsh-our-free-model-installer'
        'Accept' = 'application/vnd.github+json'
    }
    try {
        $releases = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 60 -ErrorAction Stop
    } catch {
        Write-WarnMsg ("访问 GitHub API 失败：" + $_.Exception.Message)
        return $null
    }
    if ($null -eq $releases) { return $null }

    $best = $null
    foreach ($release in @($releases)) {
        if ($release.draft -or $release.prerelease) { continue }
        $tag = [string](Get-PropertyValue $release 'tag_name')
        if ($tag -notmatch '^v?(\d+\.\d+\.\d+)$') { continue }
        $candidateVersion = $Matches[1]
        $tarballAsset = $null
        $sumsAsset = $null
        foreach ($asset in @($release.assets)) {
            $assetName = [string](Get-PropertyValue $asset 'name')
            if ($assetName -eq ("dsh-our-free-model-" + $candidateVersion + ".tgz")) { $tarballAsset = $asset }
            if ($assetName -eq 'SHA256SUMS') { $sumsAsset = $asset }
        }
        if ($null -eq $tarballAsset) { continue }
        if ($null -eq $best -or ([version]$candidateVersion -gt [version]$best.Version)) {
            $sumsUrl = $null
            if ($null -ne $sumsAsset) { $sumsUrl = [string](Get-PropertyValue $sumsAsset 'browser_download_url') }
            $best = [pscustomobject]@{
                Version     = $candidateVersion
                TarballUrl  = [string](Get-PropertyValue $tarballAsset 'browser_download_url')
                ChecksumsUrl = $sumsUrl
            }
        }
    }
    return $best
}

function Get-RemoteFile([string]$Url, [string]$Destination, [string]$Label) {
    try {
        $protocols = [Net.SecurityProtocolType]::Tls12
        try { $protocols = $protocols -bor [Net.SecurityProtocolType]::Tls13 } catch { }
        [Net.ServicePointManager]::SecurityProtocol = $protocols
    } catch {
        # 旧版 .NET 不支持 TLS 1.3 时保持默认
    }
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = 'dsh-our-free-model-installer'
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 180000
    $request.AllowAutoRedirect = $true
    $response = $null
    try {
        $response = $request.GetResponse()
    } catch {
        throw ("下载失败（" + $Label + "）：" + $_.Exception.Message)
    }
    $stream = $null
    $file = $null
    $buffer = New-Object byte[] 262144
    $written = 0
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastUpdate = 0
    try {
        $total = $response.ContentLength
        $stream = $response.GetResponseStream()
        $file = [System.IO.File]::Create($Destination)
        while ($true) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $file.Write($buffer, 0, $read)
            $written += $read
            if (($stopwatch.ElapsedMilliseconds - $lastUpdate) -ge 250) {
                $lastUpdate = $stopwatch.ElapsedMilliseconds
                if ($total -gt 0) {
                    $percent = [int]([math]::Min(100, [math]::Floor($written * 100 / $total)))
                    $status = ("{0:N1} MB / {1:N1} MB" -f ($written / 1MB), ($total / 1MB))
                    Write-Progress -Activity ("下载 " + $Label) -Status $status -PercentComplete $percent
                } else {
                    $status = ("{0:N1} MB" -f ($written / 1MB))
                    Write-Progress -Activity ("下载 " + $Label) -Status $status -PercentComplete -1
                }
            }
        }
    } finally {
        if ($file) { $file.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Close() }
        Write-Progress -Activity ("下载 " + $Label) -Completed
    }
}

function Get-ExpectedHash([string]$SumsUrl, [string]$FileName) {
    if ([string]::IsNullOrWhiteSpace($SumsUrl)) { return $null }
    $temporary = Join-Path $env:TEMP ('ofm-SHA256SUMS-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        Get-RemoteFile -Url $SumsUrl -Destination $temporary -Label 'SHA256SUMS'
    } catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        Write-WarnMsg ("下载校验文件失败：" + $_.Exception.Message)
        return $null
    }
    $text = ''
    try {
        $text = [System.IO.File]::ReadAllText($temporary, [System.Text.Encoding]::UTF8)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
            $hash = $Matches[1].ToLowerInvariant()
            $name = $Matches[2]
            if ($name -eq $FileName) { return $hash }
        }
    }
    return $null
}

function Get-TarballInfo([string]$TarballPath) {
    $tar = Get-TarPath
    if ($null -eq $tar) {
        Stop-Script '未找到 tar.exe（Windows 10 1803 及以上自带）。请升级系统或手动解压检查插件包。'
    }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & $tar -xOf $TarballPath 'package/package.json' 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0 -or $null -eq $lines) {
        Stop-Script ("无法读取插件包内容（文件可能已损坏，或不是有效的 .tgz）：" + $TarballPath)
    }
    $textLines = @($lines | Where-Object { $_ -is [string] })
    if ($textLines.Count -eq 0) {
        Stop-Script ("插件包内没有 package/package.json：" + $TarballPath)
    }
    $json = ($textLines -join "`n")
    $package = $null
    try {
        $package = $json | ConvertFrom-Json
    } catch {
        Stop-Script ("插件包内的 package.json 不是有效 JSON：" + $TarballPath)
    }
    $name = [string](Get-PropertyValue $package 'name')
    $packageVersion = [string](Get-PropertyValue $package 'version')
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($packageVersion)) {
        Stop-Script ("插件包 package.json 缺少 name/version：" + $TarballPath)
    }
    return [pscustomobject]@{ Name = $name; Version = $packageVersion }
}

# ---------------------------------------------------------------------------
# 安装计划：确定版本、本地插件包位置、是否需要下载
# ---------------------------------------------------------------------------
function Resolve-PackagePlan([switch]$PlanOnly) {
    $targetVersion = $null
    $localTarball = $null
    $fileNameVersion = $null

    if (-not [string]::IsNullOrWhiteSpace($Tarball)) {
        $localTarball = Resolve-ExistingPath $Tarball
        if ($null -eq $localTarball) { Stop-Script ("找不到 -Tarball 指定的文件：" + $Tarball) }
        if ($localTarball -notmatch '\.tgz$') { Stop-Script ("-Tarball 必须是 .tgz 插件包：" + $localTarball) }
        $leaf = Split-Path -Leaf $localTarball
        if ($leaf -match '^dsh-our-free-model-(\d+\.\d+\.\d+)\.tgz$') { $fileNameVersion = $Matches[1] }
    }

    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        if ($Version -notmatch '^v?(\d+\.\d+\.\d+)$') {
            Stop-Script ("版本号格式应为 X.Y.Z（例如 2.8.9）：" + $Version)
        }
        $targetVersion = $Matches[1]
        if ($fileNameVersion -and $fileNameVersion -ne $targetVersion) {
            Stop-Script ("-Version " + $targetVersion + " 与插件包文件名中的版本 " + $fileNameVersion + " 不一致。")
        }
    } elseif ($null -ne $localTarball) {
        if ($fileNameVersion) { $targetVersion = $fileNameVersion }
    } else {
        Write-Step '查询 GitHub 最新正式版本...'
        $release = Get-LatestRelease
        if ($null -eq $release) {
            Stop-Script ("无法获取版本信息（GitHub API 不可用）。请检查网络后重试，或用 -Version 2.8.9 / -Tarball <本地插件包> 指定。")
        }
        $targetVersion = $release.Version
        Write-Detail ("最新正式版本：v" + $targetVersion)
    }

    # 本地插件包文件名不带版本时，从包内读取版本（此时无法先做校验和比对）
    if ([string]::IsNullOrWhiteSpace($targetVersion)) {
        $info = Get-TarballInfo $localTarball
        if ($info.Name -ne $script:PackageName) {
            Stop-Script ("该插件包不是 " + $script:PackageName + "（实际包名：" + $info.Name + "）")
        }
        $targetVersion = $info.Version
    }

    $releaseBase = "https://github.com/$($script:RepoSlug)/releases/download/v$targetVersion"
    $downloadUrl = "$releaseBase/dsh-our-free-model-$targetVersion.tgz"
    $sumsUrl = "$releaseBase/SHA256SUMS"

    $vendorDir = Join-Path $script:ProfileDir 'vendor'
    $vendorTarball = Join-Path $vendorDir ("dsh-our-free-model-" + $targetVersion + ".tgz")

    $plan = [pscustomobject]@{
        Version      = $targetVersion
        VendorDir    = $vendorDir
        TgzPath      = $vendorTarball
        DownloadUrl  = $downloadUrl
        SumsUrl      = $sumsUrl
        ExpectedHash = $null
        NeedsDownload = $false
        FromLocal    = ($null -ne $localTarball)
        LocalPath    = $localTarball
    }

    if ($PlanOnly) {
        # 只做规划：不访问网络，仅判断本地是否已有可用缓存
        if ($null -eq $localTarball -and -not (Test-Path -LiteralPath $vendorTarball)) {
            $plan.NeedsDownload = $true
        }
        return $plan
    }

    # 官方校验值
    if (-not $SkipChecksum) {
        Write-Detail '获取官方 SHA-256 校验值...'
        $expected = Get-ExpectedHash -SumsUrl $sumsUrl -FileName ("dsh-our-free-model-" + $targetVersion + ".tgz")
        if ($null -eq $expected) {
            Stop-Script ("未能在发布页取得校验值（SHA256SUMS 缺失或无法下载），为安全起见已停止。" +
                "请稍后重试；确认来源可信时可用 -SkipChecksum 跳过校验。")
        }
        $plan.ExpectedHash = $expected
    } else {
        Write-WarnMsg '已跳过 SHA-256 校验（-SkipChecksum）。'
    }

    if ($null -ne $localTarball) {
        $hash = Get-Sha256 $localTarball
        if ($plan.ExpectedHash -and $hash -ne $plan.ExpectedHash) {
            Stop-Script ("SHA-256 校验失败：本地插件包与官方发布不一致（期望 " + $plan.ExpectedHash + "，实际 " + $hash + "）。")
        }
        $info = Get-TarballInfo $localTarball
        if ($info.Name -ne $script:PackageName) {
            Stop-Script ("该插件包不是 " + $script:PackageName + "（实际包名：" + $info.Name + "）")
        }
        if ($info.Version -ne $targetVersion) {
            Stop-Script ("插件包实际版本 " + $info.Version + " 与目标版本 " + $targetVersion + " 不一致。")
        }
        Ensure-Directory $vendorDir
        if ($localTarball -ne $vendorTarball) {
            Copy-Item -LiteralPath $localTarball -Destination $vendorTarball -Force
        }
        Write-Detail ("插件包已放置：" + $vendorTarball)
        return $plan
    }

    $cacheUsable = $false
    if (Test-Path -LiteralPath $vendorTarball) {
        if ($SkipChecksum) {
            $cacheUsable = $true
        } elseif ($plan.ExpectedHash) {
            try {
                if ((Get-Sha256 $vendorTarball) -eq $plan.ExpectedHash) { $cacheUsable = $true }
            } catch {
                $cacheUsable = $false
            }
        }
        if ($cacheUsable) {
            Write-Detail '使用已缓存的插件包。'
        } else {
            Write-WarnMsg '缓存插件包校验不通过，将重新下载。'
            Remove-Item -LiteralPath $vendorTarball -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $cacheUsable) {
        $plan.NeedsDownload = $true
    }
    return $plan
}

function Save-Tarball($Plan) {
    Ensure-Directory $Plan.VendorDir
    $temporary = Join-Path $env:TEMP ('dsh-our-free-model-' + $Plan.Version + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tgz')
    try {
        Get-RemoteFile -Url $Plan.DownloadUrl -Destination $temporary -Label ("Our Free Model v" + $Plan.Version)
        if ($Plan.ExpectedHash) {
            $hash = Get-Sha256 $temporary
            if ($hash -ne $Plan.ExpectedHash) {
                Stop-Script ("下载的插件包 SHA-256 校验失败：期望 " + $Plan.ExpectedHash + "，实际 " + $hash + "。")
            }
        }
        if (Test-Path -LiteralPath $Plan.TgzPath) { Remove-Item -LiteralPath $Plan.TgzPath -Force }
        Move-Item -LiteralPath $temporary -Destination $Plan.TgzPath -Force
        Write-Ok ("已下载并通过校验：" + $Plan.TgzPath)
    } catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        Stop-Script ("下载失败：" + $_.Exception.Message +
            "`n可手动从 https://github.com/$($script:RepoSlug)/releases 下载对应版本的 .tgz，再用 -Tarball 指定。")
    }
}

# ---------------------------------------------------------------------------
# 安装后 / 卸载后的提示
# ---------------------------------------------------------------------------
function Write-InstallNextSteps([string]$InstalledVersion) {
    $packageDir = Get-InstalledPackageDir
    $tarballPath = Join-Path (Join-Path $script:ProfileDir 'vendor') ("dsh-our-free-model-" + $InstalledVersion + ".tgz")
    $dataDir = Join-Path $script:DshHomePath 'our-free-model'

    Write-Host ''
    Write-Host '  ================== 安装成功 ==================' -ForegroundColor Green
    Write-Host ''
    Write-Detail ("插件版本：v" + $InstalledVersion)
    Write-Detail ("目标 profile：" + $script:ProfileName + "（" + $script:ProfileDir + "）")
    Write-Detail ("插件目录：" + $packageDir)
    if (Test-Path -LiteralPath $tarballPath) { Write-Detail ("插件包缓存：" + $tarballPath) }
    Write-Host ''
    Write-Host '  接下来：' -ForegroundColor Cyan
    if ($script:ProfileName -ieq 'desktop') {
        if ($script:AppRunning) {
            Write-Detail '1. 完全退出 DeepSeek Harness：右键任务栏托盘图标 → 退出（只关窗口不算）。'
            Write-Detail '2. 重新启动 DeepSeek Harness。'
        } else {
            Write-Detail '1. 启动 DeepSeek Harness。'
        }
        Write-Detail '3. 打开 设置 → Our Free Model（首次进入会有 5 页公告，确认一次即可）。'
        Write-Detail '4. 在对话框的模型选择器中选择免费模型；免费车道无需登录或 API Key。'
    } else {
        Write-Detail '1. 重启使用该 profile 的 DeepSeek Harness 进程。'
        Write-Detail '2. 在设置页确认 Our Free Model 已出现。'
    }
    Write-Detail ("插件数据目录：" + $dataDir + "（卸载时保留）")
    Write-Host ''
}

function Write-UninstallNextSteps {
    $dataDir = Join-Path $script:DshHomePath 'our-free-model'
    Write-Host ''
    Write-Ok ("已从 profile「" + $script:ProfileName + "」卸载 " + $script:PackageName + "。")
    Write-Host ''
    if ($script:AppRunning) {
        Write-Detail '请完全退出（托盘 → 退出）并重新启动 DeepSeek Harness，插件才会从界面中消失。'
    } else {
        Write-Detail '下次启动 DeepSeek Harness 时生效。'
    }
    Write-Detail ("插件包缓存与数据目录保留：" + $dataDir)
    Write-Detail '如需彻底清理，可手动删除插件数据目录，以及 profile 目录下 vendor\ 中的插件包。'
    Write-Host ''
}

# ---------------------------------------------------------------------------
# 安装流程
# ---------------------------------------------------------------------------
function Invoke-InstallFlow {
    # 已用 npm scoped 包安装时不能混装（同一个 profile 只能有一种安装方式）
    $manifest = Read-ProfileManifest
    if ($null -ne $manifest) {
        $dependencies = Get-PropertyValue $manifest 'dependencies'
        if ($null -ne (Get-PropertyValue $dependencies $script:ScopedPackageName)) {
            Stop-Script ("检测到该 profile 已用 npm 包 " + $script:ScopedPackageName + " 安装。" +
                "同一 profile 只能保留一种安装方式：请先执行 `dsh plugin --profile " + $script:ProfileName + " remove " +
                $script:ScopedPackageName + "`，再运行本脚本。")
        }
        $bundles = Get-BundleList $manifest
        if ($bundles -contains $script:ScopedPackageName) {
            Stop-Script ("检测到 dsh.profile.bundles 中已有 " + $script:ScopedPackageName +
                "，请先用 dsh CLI 移除，再运行本脚本。")
        }
    }

    $plan = Resolve-PackagePlan -PlanOnly:$DryRun
    Write-Detail ("目标版本：v" + $plan.Version)

    if ($DryRun) {
        $installedVersion = Get-InstalledVersion
        Write-Host ''
        Write-Step 'DryRun：环境检测完成，实际运行时将执行以下操作（本次未做任何修改）：'
        if ($installedVersion) { Write-Detail ("当前已安装版本：v" + $installedVersion) }
        if ($plan.FromLocal) { Write-Detail ("本地插件包：" + $plan.LocalPath) }
        if ($plan.NeedsDownload) { Write-Detail ("下载：" + $plan.DownloadUrl) }
        else { Write-Detail ("使用插件包：" + $plan.TgzPath) }
        Write-Detail ("运行：" + $script:CliPath + ' plugin --profile ' + $script:ProfileName + ' add "' + $plan.TgzPath + '"')
        Write-Host ''
        Write-Ok 'DryRun 完成：环境可用。'
        return
    }

    if ($plan.NeedsDownload) {
        Write-Step ("下载插件包 v" + $plan.Version + '...')
        Save-Tarball $plan
    }

    # 安装前再核对一次插件包内容
    $info = Get-TarballInfo $plan.TgzPath
    if ($info.Name -ne $script:PackageName) {
        Stop-Script ("插件包内容异常：包名 " + $info.Name + "，期望 " + $script:PackageName + "。")
    }
    if ($info.Version -ne $plan.Version) {
        Stop-Script ("插件包内容异常：版本 " + $info.Version + "，期望 " + $plan.Version + "。")
    }
    if (-not $SkipChecksum -and $plan.ExpectedHash) {
        $hash = Get-Sha256 $plan.TgzPath
        if ($hash -ne $plan.ExpectedHash) {
            Stop-Script ("插件包 SHA-256 校验失败：期望 " + $plan.ExpectedHash + "，实际 " + $hash + "。")
        }
    }

    # 已安装同版本则跳过
    $installedVersion = Get-InstalledVersion
    if ($installedVersion -and $installedVersion -eq $plan.Version -and -not $Force) {
        $problems = Get-InstallProblems $plan.Version
        if ($problems.Count -eq 0) {
            Write-Step '检查现有安装'
            Write-Ok ("已安装 v" + $installedVersion + '，无需重复安装。如确需重装，请加 -Force。')
            Write-InstallNextSteps $installedVersion
            return
        }
        Write-WarnMsg ("现有安装不完整，将重新安装：`n    - " + ($problems -join "`n    - "))
    } elseif ($installedVersion -and $installedVersion -ne $plan.Version) {
        Write-Step ("更新插件：v" + $installedVersion + " → v" + $plan.Version)
    } else {
        Write-Step ("安装 Our Free Model v" + $plan.Version + " 到 profile「" + $script:ProfileName + "」...")
    }

    $code = Invoke-DshCli -Arguments @('plugin', '--profile', $script:ProfileName, 'add', $plan.TgzPath)
    if ($code -ne 0) {
        Stop-Script ("安装命令失败（退出码 " + $code + "）。请查看上方 dsh/pnpm 输出，常见原因见 README 的「常见问题」。")
    }

    $problems = Get-InstallProblems $plan.Version
    if ($problems.Count -gt 0) {
        Stop-Script ("安装后检查未通过：`n  - " + ($problems -join "`n  - "))
    }
    Write-InstallNextSteps $plan.Version
}

# ---------------------------------------------------------------------------
# 卸载流程
# ---------------------------------------------------------------------------
function Invoke-UninstallFlow {
    $manifest = Read-ProfileManifest
    $dependencies = $null
    if ($null -ne $manifest) { $dependencies = Get-PropertyValue $manifest 'dependencies' }
    $hasDependency = $null -ne (Get-PropertyValue $dependencies $script:PackageName)
    $installedVersion = Get-InstalledVersion

    if (-not $hasDependency -and [string]::IsNullOrWhiteSpace($installedVersion)) {
        Write-Step '检查安装状态'
        Write-Ok ("profile「" + $script:ProfileName + "」中没有安装 " + $script:PackageName + '，无需卸载。')
        return
    }

    if ($DryRun) {
        Write-Host ''
        Write-Step 'DryRun：实际运行时将执行以下操作（本次未做任何修改）：'
        if ($installedVersion) { Write-Detail ("当前已安装版本：v" + $installedVersion) }
        Write-Detail ("运行：" + $script:CliPath + ' plugin --profile ' + $script:ProfileName + ' remove ' + $script:PackageName)
        Write-Host ''
        Write-Ok 'DryRun 完成。'
        return
    }

    Write-Step ("从 profile「" + $script:ProfileName + "」卸载 " + $script:PackageName + '...')
    $code = Invoke-DshCli -Arguments @('plugin', '--profile', $script:ProfileName, 'remove', $script:PackageName)
    if ($code -ne 0) {
        Stop-Script ("卸载命令失败（退出码 " + $code + "）。请查看上方 dsh/pnpm 输出。")
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $manifestAfter = Read-ProfileManifest
    $dependenciesAfter = $null
    if ($null -ne $manifestAfter) { $dependenciesAfter = Get-PropertyValue $manifestAfter 'dependencies' }
    if ($null -ne (Get-PropertyValue $dependenciesAfter $script:PackageName)) {
        $problems.Add(("package.json 的 dependencies 中仍保留 " + $script:PackageName))
    }
    if (-not [string]::IsNullOrWhiteSpace((Get-InstalledVersion))) {
        $problems.Add('插件目录仍然存在')
    }
    if ($problems.Count -gt 0) {
        Stop-Script ("卸载后检查未通过：`n  - " + ($problems -join "`n  - "))
    }
    $bundlesAfter = Get-BundleList $manifestAfter
    if ($bundlesAfter -contains $script:PackageName) {
        Write-WarnMsg ("dsh.profile.bundles 中仍保留 " + $script:PackageName + "，可手动从 profile 的 package.json 中移除。")
    }
    Write-UninstallNextSteps
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
function Invoke-Main {
    Write-Banner

    $script:TranscriptPath = Join-Path $env:TEMP ('our-free-model-install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    try {
        Start-Transcript -Path $script:TranscriptPath -Force | Out-Null
        $script:TranscriptStarted = $true
    } catch {
        $script:TranscriptStarted = $false
    }

    Resolve-Environment

    if ($Uninstall) {
        Invoke-UninstallFlow
    } else {
        Invoke-InstallFlow
    }

    if ($script:TranscriptStarted -and $script:TranscriptPath) {
        Write-Note ("本次日志：" + $script:TranscriptPath)
    }
}

try {
    Invoke-Main
} catch {
    Write-FailMsg ("脚本异常终止：" + $_.Exception.Message)
    Write-Detail ("错误位置：" + $_.InvocationInfo.PositionMessage)
    exit 1
} finally {
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

exit 0
