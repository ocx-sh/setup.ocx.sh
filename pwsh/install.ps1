# install.ps1 — OCX installer for Windows
# https://ocx.sh
#
# Usage:
#   irm https://setup.ocx.sh/pwsh | iex
#   $env:OCX_NO_MODIFY_PATH = '1'; irm https://setup.ocx.sh/pwsh | iex
#   & { $Version = '0.5.0'; irm https://setup.ocx.sh/pwsh | iex }
#   pwsh -File install.ps1 -Version 0.5.0
#
# Stdout/stderr contract (v2):
#   - All informational/warning/error messages go to STDERR.
#   - STDOUT is silent on success unless OCX_INSTALL_PRINT_PATH=1 (or
#     -PrintPath), in which case the FINAL stdout line is the absolute
#     path to the OCX bin dir.
#
# Exit codes:
#   0  success
#   1  generic / legacy
#   2  argument or environment validation
#   3  network / download / API failure
#   4  checksum mismatch
#   5  archive extraction failure
#   6  bootstrap failure
#   7  unsupported platform / architecture

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Version = '',
    [switch]$NoModifyPath,
    [switch]$Quiet,
    [switch]$Force,
    [switch]$PrintPath,
    [switch]$SkipBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Truthy helper ---

function Test-Truthy {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    return $Value -match '^(1|true|yes)$'
}

# --- Configuration (env-driven, Bazelisk-style) ---

$OcxInstallRepo                 = if ($env:OCX_INSTALL_REPO)                { $env:OCX_INSTALL_REPO }                else { 'ocx-sh/ocx' }
$OcxInstallBaseUrl              = if ($env:OCX_INSTALL_BASE_URL)            { $env:OCX_INSTALL_BASE_URL }            else { "https://github.com/$OcxInstallRepo/releases/download" }
$OcxInstallApiUrl               = if ($env:OCX_INSTALL_API_URL)             { $env:OCX_INSTALL_API_URL }             else { "https://api.github.com/repos/$OcxInstallRepo/releases" }
$OcxInstallFormatUrl            = if ($env:OCX_INSTALL_FORMAT_URL)          { $env:OCX_INSTALL_FORMAT_URL }          else { "$OcxInstallBaseUrl/{tag}/ocx-{target}.{ext}" }
$OcxInstallChecksumFormatUrl    = if ($env:OCX_INSTALL_CHECKSUM_FORMAT_URL) { $env:OCX_INSTALL_CHECKSUM_FORMAT_URL } else { "$OcxInstallBaseUrl/{tag}/sha256.sum" }

# Environment wins over switches (Bazelisk parity).
$OcxInstallSkipBootstrap   = if (Test-Truthy $env:OCX_INSTALL_SKIP_BOOTSTRAP)   { $true } else { [bool]$SkipBootstrap }
$OcxInstallPrintPath       = if (Test-Truthy $env:OCX_INSTALL_PRINT_PATH)      { $true } else { [bool]$PrintPath }
$OcxInstallForce           = if (Test-Truthy $env:OCX_INSTALL_FORCE)           { $true } else { [bool]$Force }
$OcxInstallQuiet           = if (Test-Truthy $env:OCX_INSTALL_QUIET)           { $true } else { [bool]$Quiet }
$OcxInstallNoBinSmoketest  = Test-Truthy $env:OCX_INSTALL_NO_BIN_SMOKETEST
$OcxNoModifyPath           = if (Test-Truthy $env:OCX_NO_MODIFY_PATH)          { $true } else { [bool]$NoModifyPath }

# --- Output helpers (all go to STDERR) ---

function Say {
    param([string]$Message)
    if ($OcxInstallQuiet) { return }
    [Console]::Error.WriteLine("ocx-install: $Message")
}

function Err {
    param([string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine("ocx-install: error: $Message")
    exit $Code
}

function Warn {
    param([string]$Message)
    [Console]::Error.WriteLine("ocx-install: warning: $Message")
}

# --- URL templating ---

function Format-OcxUrl {
    param(
        [string]$Template,
        [string]$Version,
        [string]$Tag,
        [string]$Target,
        [string]$Ext
    )
    return $Template `
        -replace '\{version\}', $Version `
        -replace '\{tag\}',     $Tag `
        -replace '\{target\}',  $Target `
        -replace '\{ext\}',     $Ext
}

# --- Platform detection ---

function Detect-Architecture {
    try {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        switch ($arch) {
            'X64'   { return 'x86_64-pc-windows-msvc' }
            'Arm64' { return 'aarch64-pc-windows-msvc' }
            'X86'   { Err '32-bit Windows is not supported. OCX requires a 64-bit system.' 7 }
            'Arm'   { Err '32-bit ARM Windows is not supported. OCX requires a 64-bit system.' 7 }
            default { Err "Unsupported architecture: $arch" 7 }
        }
    }
    catch {
        # Fallback for older PowerShell / .NET versions
    }

    $procArch = $env:PROCESSOR_ARCHITECTURE
    switch ($procArch) {
        'AMD64' { return 'x86_64-pc-windows-msvc' }
        'ARM64' { return 'aarch64-pc-windows-msvc' }
        'x86'   { Err '32-bit Windows is not supported. OCX requires a 64-bit system.' 7 }
        default { Err "Unsupported architecture: $procArch" 7 }
    }
}

# --- Download utilities ---

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    $headers = @{}
    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "token $env:GITHUB_TOKEN"
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $Destination -Headers $headers -UseBasicParsing
    }
    catch {
        return $false
    }
    return $true
}

function Download-String {
    param([string]$Url)

    $headers = @{}
    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "token $env:GITHUB_TOKEN"
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

    $ProgressPreference = 'SilentlyContinue'
    (Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing).Content
}

# --- Checksum verification ---

function Verify-Checksum {
    param(
        [string]$Dir,
        [string]$File
    )

    $checksumFile = Join-Path $Dir 'sha256.sum'
    $checksumContent = Get-Content $checksumFile -Raw

    $expected = $null
    foreach ($line in $checksumContent.Split("`n")) {
        $line = $line.Trim()
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+(.+)$') {
            $matchedFile = $Matches[2].Trim().TrimStart('*')
            if ($matchedFile -eq $File) {
                $expected = $Matches[1].ToLower()
                break
            }
        }
    }

    if (-not $expected) {
        Err "Checksum for $File not found in sha256.sum" 4
    }

    $filePath = Join-Path $Dir $File
    $actual = (Get-FileHash -Path $filePath -Algorithm SHA256).Hash.ToLower()

    if ($expected -ne $actual) {
        Err "Checksum mismatch for $File`n  expected: $expected`n  got:      $actual" 4
    }

    Say 'Checksum verified.'
}

# --- Version resolution ---

function Get-LatestVersion {
    try {
        $releaseInfo = Download-String "$OcxInstallApiUrl/latest"
    }
    catch {
        if (-not $env:GITHUB_TOKEN) {
            Err "Failed to fetch latest release from GitHub.`nThis may be a rate-limit issue. Try setting GITHUB_TOKEN:`n  `$env:GITHUB_TOKEN = 'ghp_...'`n  irm https://setup.ocx.sh/pwsh | iex" 3
        }
        else {
            Err 'Failed to fetch latest release from GitHub — check your internet connection and token.' 3
        }
    }

    if ($releaseInfo -match '"tag_name"\s*:\s*"([^"]+)"') {
        $tag = $Matches[1]
        return $tag -replace '^v', ''
    }

    Err 'Could not determine latest version from GitHub.' 3
}

# --- Environment file creation ---

function Create-EnvFile {
    param([string]$OcxHome)

    $envFile = Join-Path $OcxHome 'env.ps1'

    $envContent = @'
# OCX shell environment - generated by install.ps1
# Sourced by your PowerShell profile to add OCX to PATH and enable completions.
# Manual changes will be overwritten on reinstall.
$_OcxHome = if ($env:OCX_HOME) { $env:OCX_HOME } else { Join-Path $env:USERPROFILE '.ocx' }
$_OcxBin = Join-Path $_OcxHome 'symlinks\ocx.sh\ocx\current\bin'
if ($env:PATH -notlike "*$_OcxBin*") {
    $env:PATH = "$_OcxBin;$env:PATH"
}
$_OcxExe = Join-Path $_OcxBin 'ocx.exe'
if (Test-Path $_OcxExe) {
    try {
        $_OcxProfile = & $_OcxExe --offline shell profile load --shell powershell 2>$null | Out-String
        if ($_OcxProfile.Trim()) { $_OcxProfile | Invoke-Expression }
    } catch {}
    Remove-Variable _OcxProfile -ErrorAction SilentlyContinue
    try { & $_OcxExe --offline shell completion --shell powershell 2>$null | Out-String | Invoke-Expression } catch {}
}
Remove-Variable _OcxHome, _OcxBin, _OcxExe -ErrorAction SilentlyContinue
'@

    Set-Content -Path $envFile -Value $envContent -Encoding UTF8
}

# --- Profile modification ---

function Modify-Profile {
    param([string]$OcxHome)

    $profilePath = $PROFILE.CurrentUserCurrentHost

    if ($OcxHome -eq (Join-Path $env:USERPROFILE '.ocx')) {
        $sourceLine = 'if (Test-Path "$env:USERPROFILE\.ocx\env.ps1") { . "$env:USERPROFILE\.ocx\env.ps1" }'
    }
    else {
        $sourceLine = "if (Test-Path `"$OcxHome\env.ps1`") { . `"$OcxHome\env.ps1`" }"
    }

    $profileDir = Split-Path $profilePath -Parent
    if ($profileDir -and -not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }

    if (-not (Test-Path $profilePath)) {
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
    }

    $profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if ($profileContent -and $profileContent.Contains('.ocx\env.ps1')) {
        Say "PowerShell profile already configured ($profilePath)."
        return
    }

    Add-Content -Path $profilePath -Value "`n# OCX`n$sourceLine"
    Say "Added OCX to $profilePath"
}

# --- Skip-bootstrap install path ---

function Install-WithoutBootstrap {
    param(
        [string]$Bin,
        [string]$Version,
        [string]$OcxHome
    )

    Say 'Installing without bootstrap (OCX_INSTALL_SKIP_BOOTSTRAP=1)...'
    $store = Join-Path $OcxHome 'symlinks\ocx.sh\ocx'
    $verDir = Join-Path $store $Version
    $binDir = Join-Path $verDir 'bin'
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    Copy-Item -Path $Bin -Destination (Join-Path $binDir 'ocx.exe') -Force

    $currentLink = Join-Path $store 'current'
    if (Test-Path $currentLink) {
        Remove-Item -Path $currentLink -Force -Recurse -ErrorAction SilentlyContinue
    }
    # Junction works for both admin and non-admin contexts on Windows.
    cmd /c mklink /J "$currentLink" "$verDir" | Out-Null
}

# --- Success message ---

function Print-Success {
    param(
        [string]$InstalledVersion,
        [string]$OldVersion = ''
    )

    if ($OcxInstallQuiet) { return }

    $ocxHome = if ($env:OCX_HOME) { $env:OCX_HOME } else { Join-Path $env:USERPROFILE '.ocx' }

    [Console]::Error.WriteLine('')
    if ($OldVersion -and $OldVersion -ne $InstalledVersion) {
        [Console]::Error.WriteLine("  ocx upgraded: $OldVersion -> $InstalledVersion")
    }
    else {
        [Console]::Error.WriteLine("  ocx $InstalledVersion installed successfully!")
    }

    [Console]::Error.WriteLine(@"

  To get started, restart your shell or run:

    . "$ocxHome\env.ps1"

  Then verify with:

    ocx info

  To uninstall, remove the OCX home directory:

    Remove-Item -Recurse -Force "$ocxHome"

"@)
}

# --- Main ---

function Main {
    # Caller-scope $Version fallback (for `& { $Version = '0.5.0'; irm ... | iex }` idiom).
    # The script-level param $Version takes precedence.
    if (-not $script:Version) {
        $callerVersion = Get-Variable -Name 'Version' -Scope 1 -ErrorAction SilentlyContinue
        if ($callerVersion -and $callerVersion.Value) {
            $script:Version = $callerVersion.Value
        }
    }
    $requestedVersion = $script:Version

    $ocxHome = if ($env:OCX_HOME) { $env:OCX_HOME } else { Join-Path $env:USERPROFILE '.ocx' }

    $target = Detect-Architecture
    Say "Detected platform: $target"

    if (-not $requestedVersion) {
        Say 'Fetching latest version...'
        $requestedVersion = Get-LatestVersion
    }

    if ($requestedVersion -notmatch '^\d+\.\d+\.\d+') {
        Err "Invalid version format: $requestedVersion (expected semver like 1.2.3)" 2
    }

    $oldVersion = ''
    $existingBin = Join-Path $ocxHome 'symlinks\ocx.sh\ocx\current\bin\ocx.exe'
    if (Test-Path $existingBin) {
        try { $oldVersion = & $existingBin version 2>$null } catch {}
    }

    # Force / idempotent fast-path
    $installBinDir = Join-Path $ocxHome 'symlinks\ocx.sh\ocx\current\bin'
    if ($oldVersion -and ($oldVersion -eq $requestedVersion) -and -not $OcxInstallForce) {
        Say "ocx v$requestedVersion already installed at $installBinDir\ocx.exe (set OCX_INSTALL_FORCE=1 to reinstall)"
        if ($OcxInstallPrintPath) { Write-Output $installBinDir }
        Export-GithubPath -OcxHome $ocxHome
        return
    }

    Say "Installing ocx v$requestedVersion..."

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-install-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    try {
        $ext = 'zip'
        $tag = "v$requestedVersion"
        $archive = "ocx-$target.$ext"
        $archiveUrl  = Format-OcxUrl -Template $OcxInstallFormatUrl         -Version $requestedVersion -Tag $tag -Target $target -Ext $ext
        $checksumUrl = Format-OcxUrl -Template $OcxInstallChecksumFormatUrl -Version $requestedVersion -Tag $tag -Target $target -Ext $ext

        Say "Downloading $archive..."
        $downloaded = Download-File -Url $archiveUrl -Destination (Join-Path $tmpDir $archive)
        if (-not $downloaded) {
            Err "Failed to download $archiveUrl`nEnsure v$requestedVersion is a valid release with a binary for $target.`nAvailable releases: https://github.com/$OcxInstallRepo/releases" 3
        }

        $checksumDownloaded = Download-File -Url $checksumUrl -Destination (Join-Path $tmpDir 'sha256.sum')
        if (-not $checksumDownloaded) {
            Err "Failed to download checksums from $checksumUrl" 3
        }

        Verify-Checksum -Dir $tmpDir -File $archive

        $extractDir = Join-Path $tmpDir 'extracted'
        try {
            Expand-Archive -Path (Join-Path $tmpDir $archive) -DestinationPath $extractDir -Force
        }
        catch {
            Err "Failed to extract $archive — $($_.Exception.Message)" 5
        }

        $bin = $null
        $candidatePaths = @(
            (Join-Path $extractDir "ocx-$target\ocx.exe"),
            (Join-Path $extractDir 'ocx.exe')
        )
        foreach ($candidate in $candidatePaths) {
            if (Test-Path $candidate) {
                $bin = $candidate
                break
            }
        }

        if (-not $bin) {
            Err 'Could not find ocx.exe binary in archive.' 5
        }

        if (-not $OcxInstallNoBinSmoketest) {
            try {
                $null = & $bin version 2>$null
            }
            catch {
                Warn 'Binary failed to execute — it may be blocked by antivirus or execution policy.'
            }
        }

        $existingOcx = Get-Command ocx -ErrorAction SilentlyContinue
        if ($existingOcx -and -not $existingOcx.Source.StartsWith($ocxHome)) {
            Warn "An existing ocx was found at $($existingOcx.Source)"
            Warn 'The new install may be shadowed — check your PATH order.'
        }

        if (-not (Test-Path $ocxHome)) {
            New-Item -ItemType Directory -Path $ocxHome -Force | Out-Null
        }

        if ($OcxInstallSkipBootstrap) {
            Install-WithoutBootstrap -Bin $bin -Version $requestedVersion -OcxHome $ocxHome
        }
        else {
            Say 'Bootstrapping OCX into its own package store...'
            & $bin --remote install --select "ocx.sh/ocx:$requestedVersion"
            if ($LASTEXITCODE -ne 0) {
                Err "Bootstrap failed: 'ocx --remote install --select ocx.sh/ocx:$requestedVersion'`nEnsure ocx v$requestedVersion is published to the ocx.sh registry.`nTo skip bootstrap (offline / air-gapped), set OCX_INSTALL_SKIP_BOOTSTRAP=1." 6
            }
        }
        Say "Installed to $installBinDir\ocx.exe"

        Create-EnvFile -OcxHome $ocxHome

        if ($OcxNoModifyPath) {
            Say 'Skipping profile modification (OCX_NO_MODIFY_PATH).'
        }
        else {
            try {
                Modify-Profile -OcxHome $ocxHome
            }
            catch {
                Warn "Failed to modify PowerShell profile: $($_.Exception.Message)"
                Warn 'You can manually add OCX to your profile by running:'
                Warn "  Add-Content `$PROFILE '`. `"$ocxHome\env.ps1`"'"
            }
        }

        Export-GithubPath -OcxHome $ocxHome

        Print-Success -InstalledVersion $requestedVersion -OldVersion $oldVersion

        if ($OcxInstallPrintPath) {
            Write-Output $installBinDir
        }
    }
    finally {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
}

function Export-GithubPath {
    param([string]$OcxHome)
    if ($env:GITHUB_PATH) {
        $ghBinPath = Join-Path $OcxHome 'symlinks\ocx.sh\ocx\current\bin'
        try {
            Add-Content -Path $env:GITHUB_PATH -Value $ghBinPath
        }
        catch {
            Warn 'Failed to write to $GITHUB_PATH.'
        }
    }
}

Main
