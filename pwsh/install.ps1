# install.ps1 — OCX installer for Windows
# https://ocx.sh
#
# Windows-only. This installer targets Windows PowerShell 5.1+ and PowerShell 7+
# ON WINDOWS only (the release targets are *-pc-windows-msvc and the binary is
# ocx.exe). On Linux/macOS use the POSIX installer (sh/install.sh); this script
# intentionally does NOT support pwsh-on-Linux.
#
# Usage:
#   irm https://setup.ocx.sh/pwsh | iex
#   $env:OCX_NO_MODIFY_PATH = '1'; irm https://setup.ocx.sh/pwsh | iex
#   & ([scriptblock]::Create((irm https://setup.ocx.sh/pwsh))) -Version 0.5.0
#   pwsh -File install.ps1 -Version 0.5.0
#
# NOTE on the pinned-version one-liner: the older `& { $Version = '0.5.0';
# irm ... | iex }` idiom does NOT work — this script's param([string]$Version)
# block makes `$Version` a read-only automatic parameter inside that scope, so
# assigning to it errors. Compile the downloaded text into a script block and
# pass -Version through instead (the form shown above).
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
#   6  bootstrap ('ocx --remote package install') failure
#   7  unsupported platform / architecture

# Support Windows PowerShell 5.1+ (the default on Windows 10/11) AND PowerShell
# 7+. Zip extraction routes through Expand-ZipSafely, which validates every
# entry against zip-slip before writing — so we don't depend on Expand-Archive's
# PS 7.4 hardening.
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Version = '',
    [switch]$NoModifyPath,
    [switch]$Quiet,
    [switch]$Force,
    [switch]$PrintPath,
    [switch]$SkipSelfInit,
    [switch]$NoBinSmoketest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Truthy helper ---

function Test-Truthy {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    # Case-SENSITIVE match over exactly the 7 forms sh's is_truthy accepts:
    #   1 | true | yes | TRUE | YES | True | Yes
    # `-cmatch` (not `-match`) so 'tRuE'/'YeS' etc. are falsy, matching sh
    # parity. The pattern is anchored at both ends so trailing junk is rejected.
    return $Value -cmatch '^(1|true|yes|TRUE|YES|True|Yes)$'
}

# --- Configuration (env-driven, Bazelisk-style) ---

$OcxInstallRepo                 = if ($env:OCX_INSTALL_REPO)                { $env:OCX_INSTALL_REPO }                else { 'ocx-sh/ocx' }
$OcxInstallBaseUrl              = if ($env:OCX_INSTALL_BASE_URL)            { $env:OCX_INSTALL_BASE_URL }            else { "https://github.com/$OcxInstallRepo/releases/download" }
$OcxInstallApiUrl               = if ($env:OCX_INSTALL_API_URL)             { $env:OCX_INSTALL_API_URL }             else { "https://api.github.com/repos/$OcxInstallRepo/releases" }
$OcxInstallFormatUrl            = if ($env:OCX_INSTALL_FORMAT_URL)          { $env:OCX_INSTALL_FORMAT_URL }          else { "$OcxInstallBaseUrl/{tag}/ocx-{target}.{ext}" }
$OcxInstallChecksumFormatUrl    = if ($env:OCX_INSTALL_CHECKSUM_FORMAT_URL) { $env:OCX_INSTALL_CHECKSUM_FORMAT_URL } else { "$OcxInstallBaseUrl/{tag}/sha256.sum" }

# Behavioral knobs. Environment wins over switches (Bazelisk parity).
#
# OCX_INSTALL_SKIP_SELF_INIT: when truthy, place the extracted ocx binary at the
# canonical bin dir as a PLAIN directory (no package-store symlinks/manifests),
# put it on PATH and emit it for print-path, and SKIP both the networked
# 'ocx --remote package install' bootstrap AND env-shim/self-activate generation.
# This is binary-on-PATH only: 'ocx self update' will NOT manage such an install.
# It is the CI/GitLab path. Profile modification stays controlled by
# OCX_NO_MODIFY_PATH independently.
$OcxInstallSkipSelfInit    = if (Test-Truthy $env:OCX_INSTALL_SKIP_SELF_INIT)  { $true } else { [bool]$SkipSelfInit }
$OcxInstallPrintPath       = if (Test-Truthy $env:OCX_INSTALL_PRINT_PATH)      { $true } else { [bool]$PrintPath }
$OcxInstallForce           = if (Test-Truthy $env:OCX_INSTALL_FORCE)           { $true } else { [bool]$Force }
$OcxInstallQuiet           = if (Test-Truthy $env:OCX_INSTALL_QUIET)           { $true } else { [bool]$Quiet }
$OcxInstallNoBinSmoketest  = if (Test-Truthy $env:OCX_INSTALL_NO_BIN_SMOKETEST) { $true } else { [bool]$NoBinSmoketest }
$OcxNoModifyPath           = if (Test-Truthy $env:OCX_NO_MODIFY_PATH)          { $true } else { [bool]$NoModifyPath }

# Canonical CLI bin dir relative to OCX_HOME (real on-disk store layout):
#   $OcxHome\symlinks\ocx.sh\ocx\cli\current\content\bin
# Mirrors install.sh OCX_BIN_SUBPATH (which uses forward slashes).
$OcxBinSubPath = 'symlinks\ocx.sh\ocx\cli\current\content\bin'

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
        # RuntimeInformation.OSArchitecture is unavailable on very old
        # PowerShell / .NET Framework builds; fall through to the
        # PROCESSOR_ARCHITECTURE probe below. Surface the reason under -Verbose.
        Write-Verbose "OSArchitecture probe failed, falling back to PROCESSOR_ARCHITECTURE: $($_.Exception.Message)"
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

# TLS fail-closed gate. The mirror knobs (OCX_INSTALL_BASE_URL / FORMAT_URL /
# CHECKSUM_FORMAT_URL / API_URL) are CI-injectable, so a non-https value would
# otherwise let the archive, checksum, OR the GITHUB_TOKEN-bearing API request
# travel in plaintext. Reject any non-https URL with exit 3 before a request
# leaves the machine. Mirrors install.sh assert_https_url.
#
# Loopback (127.0.0.1 / [::1] / localhost) is exempt: the Pester + Bats fixture
# servers run on loopback and the token is never attached to a loopback host
# (Test-IsGitHubApiHost below). The leak surface is the public network, which
# this guard keeps https-only.
function Assert-HttpsUrl {
    param([string]$Url)

    if ($Url -match '^https://') { return }

    if ($Url -match '^https?://(?:127\.0\.0\.1|\[::1\]|localhost)(?::\d+)?(?:/|$)') {
        return
    }

    Err "refusing insecure (non-https) URL: $Url" 3
}

# True only when the URL's host is exactly api.github.com. The Authorization:
# token header is attached ONLY for this host (the GitHub API call in
# Get-LatestVersion) — NEVER on the mirror-derived archive/checksum URLs, which
# come from the attacker-controllable OCX_INSTALL_BASE_URL. Mirrors install.sh,
# where only download_api sends the token.
function Test-IsGitHubApiHost {
    param([string]$Url)
    try {
        return ([System.Uri]$Url).Host -eq 'api.github.com'
    }
    catch {
        return $false
    }
}

# Extract the redirect Location from a thrown Invoke-WebRequest error, across
# PowerShell editions: PS 5.1 throws WebException ([.Response] = HttpWebResponse,
# integer-castable .StatusCode); PS 7 throws HttpResponseException ([.Response] =
# HttpResponseMessage with .StatusCode + .Headers.Location). Returns the absolute
# redirect URL string for a 3xx, or $null otherwise.
function Get-RedirectLocation {
    param($ErrorRecord)
    $resp = $ErrorRecord.Exception.Response
    if ($null -eq $resp) { return $null }
    try {
        $code = [int]$resp.StatusCode
    }
    catch {
        return $null
    }
    if ($code -lt 300 -or $code -ge 400) { return $null }
    # HttpResponseMessage (PS7) exposes Headers.Location as a Uri; HttpWebResponse
    # (PS5.1) exposes Headers['Location'] as a string.
    if ($resp.PSObject.Properties.Match('Headers').Count -gt 0 -and
        $resp.Headers.PSObject.Properties.Match('Location').Count -gt 0 -and
        $resp.Headers.Location) {
        return [string]$resp.Headers.Location
    }
    try {
        return [string]$resp.Headers['Location']
    }
    catch {
        return $null
    }
}

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    # Mirror-derived (base-URL) download: archive or checksum. NEVER attach the
    # GITHUB_TOKEN here — the URL host is attacker-controllable via
    # OCX_INSTALL_BASE_URL, and the token must not leak to a third-party mirror.
    Assert-HttpsUrl $Url

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

    # Follow at most ONE redirect hop manually, re-validating the scheme on the
    # hop target. -MaximumRedirection 0 means a https->http redirect can NOT
    # silently downgrade the transport (important on Windows PowerShell 5.1,
    # which follows redirects by default and would otherwise re-send over
    # plaintext). GitHub release assets answer 302 to a signed S3 URL, so one
    # explicit, scheme-checked hop is required. -OutFile is kept (instead of
    # writing $resp.Content) so BOTH binary archives and text checksum files are
    # written byte-faithfully — $resp.Content is a string for text and byte[]
    # for binary, which a single WriteAllBytes would corrupt.
    $current = $Url
    for ($hop = 0; $hop -lt 2; $hop++) {
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $current -OutFile $Destination -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
            return $true
        }
        catch {
            $next = Get-RedirectLocation $_
            if (-not $next) { return $false }
            Assert-HttpsUrl $next
            $current = $next
        }
    }
    return $false
}

function Download-String {
    param([string]$Url)

    Assert-HttpsUrl $Url

    $headers = @{}
    # Attach the GitHub auth token ONLY when the host is api.github.com. The
    # API URL is mirror-overridable (OCX_INSTALL_API_URL), so gate on the
    # resolved host — not merely "this is the API call" — so a redirected or
    # mirror-pointed API URL never receives the token.
    if ($env:GITHUB_TOKEN -and (Test-IsGitHubApiHost $Url)) {
        $headers['Authorization'] = "token $env:GITHUB_TOKEN"
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

    $ProgressPreference = 'SilentlyContinue'
    # -MaximumRedirection 0 so a token-bearing request cannot be redirected to
    # a non-https (or non-GitHub) host with the Authorization header still set.
    (Invoke-WebRequest -Uri $Url -Headers $headers -MaximumRedirection 0 -UseBasicParsing).Content
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

# --- Archive extraction ---

# Extract a .zip with zip-slip protection on PowerShell 5.1+. Expand-Archive
# only validates entry paths from PS 7.4 onwards, so we use the .NET API
# directly and reject any entry that escapes the destination directory. We
# stay on [System.IO.*] APIs (not PowerShell cmdlets) to avoid parameter-set
# binding errors under Set-StrictMode in Windows PowerShell 5.1.
function Expand-ZipSafely {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

    [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
    $destRoot = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    $sep = [System.IO.Path]::DirectorySeparatorChar

    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            $rel = $name -replace '/', '\'

            # Reject absolute paths, drive letters, and parent-traversal segments.
            $segments = $rel.Split('\')
            if ($rel.StartsWith('\') -or $rel -match '^[A-Za-z]:' -or
                ($segments -contains '..')) {
                throw "Archive contains unsafe entry: $name"
            }

            $target = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($destRoot, $rel))
            if ($target -ne $destRoot -and
                -not $target.StartsWith($destRoot + $sep,
                    [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry escapes destination: $name"
            }

            # Directory entries (zip spec uses trailing '/').
            if ($name.EndsWith('/') -or $name.EndsWith('\')) {
                [System.IO.Directory]::CreateDirectory($target) | Out-Null
                continue
            }

            $parent = [System.IO.Path]::GetDirectoryName($target)
            if ($parent) {
                [System.IO.Directory]::CreateDirectory($parent) | Out-Null
            }

            $in = $entry.Open()
            try {
                $out = [System.IO.File]::Create($target)
                try {
                    $in.CopyTo($out)
                }
                finally { $out.Dispose() }
            }
            finally { $in.Dispose() }
        }
    }
    finally {
        $zip.Dispose()
    }
}

# --- OCX_HOME validation ---

# Defence-in-depth: $OcxHome is embedded literally into env.ps1 and the
# PowerShell profile inside double-quoted strings. Reject a path that is not
# absolute, contains '..' components, or carries characters that could break
# out of that quoting context (CWE-22 / CWE-78). Mirrors install.sh
# assert_safe_ocx_home.
function Assert-SafeOcxHome {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Err 'OCX_HOME must not be empty' 2
    }
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        Err "OCX_HOME must be an absolute path: $Path" 2
    }
    if ($Path -match '\.\.[\\/]' -or $Path -match '[\\/]\.\.$' -or $Path -eq '..') {
        Err "OCX_HOME must not contain '..' components: $Path" 2
    }
    # `"`, backtick and `$` would break the double-quoted embedding; `;` and
    # newlines would inject statements into env.ps1 / the profile. `[`, `]`,
    # `(`, `)` can interfere with PowerShell expression / index / sub-expression
    # evaluation when the path is re-interpolated. U+2028 (line separator) and
    # U+2029 (paragraph separator) are tokenized as line breaks by the
    # PowerShell parser in some hosts — treat them as injection vectors
    # (CWE-94 / CWE-78 defence-in-depth).
    if ($Path -match '["`$;\r\n\[\]()]') {
        Err "OCX_HOME contains characters unsafe for shell embedding: $Path" 2
    }
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

    # Thin shim that delegates to `ocx self activate --shell=powershell` at
    # runtime.  Single-quoted here-string (@'...'@) prevents any PowerShell
    # expansion at install time — content is byte-identical across users
    # regardless of their OcxHome path (the shim resolves OCX_HOME itself).
    $envContent = @'
# Managed by ocx installer — do not edit.
# Double-source guard — prevents PATH duplication on re-source.
# Set before any side effects so re-source after partial failure also short-circuits.
if ($env:_OCX_ENV_LOADED) { return }
$env:_OCX_ENV_LOADED = '1'

if (-not $env:OCX_HOME) { $env:OCX_HOME = Join-Path $env:USERPROFILE '.ocx' }

$_ocxBin = Join-Path $env:OCX_HOME 'symlinks/ocx.sh/ocx/cli/current/content/bin/ocx.exe'
if (Test-Path $_ocxBin -PathType Leaf) {
    Invoke-Expression ((& $_ocxBin self activate --shell=powershell 2>$null) | Out-String)
}
Remove-Variable _ocxBin -ErrorAction SilentlyContinue
'@

    Set-Content -Path $envFile -Value $envContent -NoNewline
}

# --- Profile modification ---

# Strip every OCX-managed fragment from profile lines:
#   - the # BEGIN ocx … # END ocx block (current form),
#   - the legacy bare `# OCX` marker plus its following source line,
#   - any stray legacy `ocx shell init`/`profile load` dot-source line.
# Returns the cleaned line array. Mirrors install.sh remove_legacy_profile_lines
# + the block-strip, adapted to the marker shape older install.ps1 wrote.
function Remove-OcxProfileLines {
    param([string[]]$Lines)

    $out = New-Object 'System.Collections.Generic.List[string]'
    $inBlock = $false
    $skipNext = $false

    foreach ($line in $Lines) {
        $trimmed = $line.Trim()

        if ($trimmed -eq '# BEGIN ocx') { $inBlock = $true; continue }
        if ($trimmed -eq '# END ocx') { $inBlock = $false; continue }
        if ($inBlock) { continue }

        if ($skipNext) {
            $skipNext = $false
            if ($trimmed -match '\.ocx[\\/](env|init)\.') { continue }
        }

        # Legacy bare marker written by older install.ps1; the OCX source line
        # followed it directly.
        if ($trimmed -eq '# OCX') { $skipNext = $true; continue }

        # Defensive: a legacy ocx env/init dot-source that lost its marker.
        if ($trimmed -match '\.ocx[\\/](env|init)\.[a-z0-9]+["'']?\s*\}?\s*$' -and
            $trimmed -match '(^\.\s|Test-Path)') {
            continue
        }

        $out.Add($line)
    }

    return , $out.ToArray()
}

function Modify-Profile {
    param([string]$OcxHome)

    $profilePath = $PROFILE.CurrentUserCurrentHost

    # Source line guarded with Test-Path so deleting $OcxHome never makes the
    # PowerShell profile error on startup (nvm fail-safe pattern).
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

    $existing = @()
    if (Test-Path $profilePath) {
        $raw = Get-Content $profilePath -ErrorAction SilentlyContinue
        if ($null -ne $raw) { $existing = @($raw) }
    }

    # Migrate: drop any prior OCX block / legacy marker, then re-append a
    # single canonical block. Stable across re-runs (idempotent by
    # construction — output converges regardless of prior form).
    $cleaned = @(Remove-OcxProfileLines -Lines $existing)
    while ($cleaned.Count -gt 0 -and [string]::IsNullOrWhiteSpace($cleaned[$cleaned.Count - 1])) {
        if ($cleaned.Count -eq 1) { $cleaned = @() }
        else { $cleaned = $cleaned[0..($cleaned.Count - 2)] }
    }

    $block = @('', '# BEGIN ocx', $sourceLine, '# END ocx')
    $final = @($cleaned) + $block

    Set-Content -Path $profilePath -Value $final -Encoding UTF8
    Say "Configured OCX in $profilePath"
}

# Skip-self-init profile path: no env.ps1 shim exists, so write a profile block
# that prepends the canonical bin dir to PATH directly. Mirrors install.sh
# modify_shell_profile_binary_only. Uses the same # BEGIN ocx / # END ocx block.
function Modify-ProfileBinaryOnly {
    param([string]$OcxHome)

    $profilePath = $PROFILE.CurrentUserCurrentHost
    $binDir = Join-Path $OcxHome $OcxBinSubPath

    if ($OcxHome -eq (Join-Path $env:USERPROFILE '.ocx')) {
        $sourceLine = '$_OcxBin = Join-Path $env:USERPROFILE ' +
            "'$OcxBinSubPath'" +
            '; if ($env:PATH -notlike "*$_OcxBin*") { $env:PATH = "$_OcxBin;$env:PATH" }; Remove-Variable _OcxBin -ErrorAction SilentlyContinue'
    }
    else {
        $sourceLine = "if (`$env:PATH -notlike `"*$binDir*`") { `$env:PATH = `"$binDir;`$env:PATH`" }"
    }

    $profileDir = Split-Path $profilePath -Parent
    if ($profileDir -and -not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }

    $existing = @()
    if (Test-Path $profilePath) {
        $raw = Get-Content $profilePath -ErrorAction SilentlyContinue
        if ($null -ne $raw) { $existing = @($raw) }
    }

    $cleaned = @(Remove-OcxProfileLines -Lines $existing)
    while ($cleaned.Count -gt 0 -and [string]::IsNullOrWhiteSpace($cleaned[$cleaned.Count - 1])) {
        if ($cleaned.Count -eq 1) { $cleaned = @() }
        else { $cleaned = $cleaned[0..($cleaned.Count - 2)] }
    }

    $block = @('', '# BEGIN ocx', $sourceLine, '# END ocx')
    $final = @($cleaned) + $block

    Set-Content -Path $profilePath -Value $final -Encoding UTF8
    Say "Configured OCX in $profilePath"
}

# --- Skip-self-init install path ---

# Place the extracted binary at the canonical bin dir as a PLAIN directory (no
# fabricated package-store symlinks/manifests), so it is on PATH for downstream
# consumers. This is binary-on-PATH only: 'ocx self update' will NOT manage such
# an install. It is the CI/GitLab path. Mirrors install.sh
# install_without_bootstrap (simple mkdir + copy, no version/current junction).
function Install-WithoutSelfInit {
    param(
        [string]$Bin,
        [string]$OcxHome
    )

    Say 'Installing without self-init (OCX_INSTALL_SKIP_SELF_INIT=1)...'
    $binDir = Join-Path $OcxHome $OcxBinSubPath
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    Copy-Item -Path $Bin -Destination (Join-Path $binDir 'ocx.exe') -Force
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

    ocx about

  To uninstall, remove the OCX home directory:

    Remove-Item -Recurse -Force "$ocxHome"

"@)
}

# --- Main ---

function Main {
    param([string]$RequestedVersion = '')

    # Runtime PS version check — belt-and-suspenders alongside the #Requires
    # directive above. `irm ... | iex` evaluates content as a string and
    # bypasses parser-level #Requires (which only fires when executing a .ps1
    # from disk). 5.1 is the minimum because Expand-ZipSafely uses
    # System.IO.Compression.ZipFile, which ships in .NET 4.5+. PowerShell 7+ is
    # equally supported.
    if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
        [Console]::Error.WriteLine('ocx-install: error: PowerShell 5.1+ required.')
        [Console]::Error.WriteLine('Upgrade: https://aka.ms/install-powershell')
        exit 2
    }

    # The -Version flag (passed in as $RequestedVersion) takes precedence. When
    # absent, support the legacy caller-scope `& ([scriptblock]::Create((irm
    # ...))) -Version X` idiom AND a caller-set $Version variable, then fall
    # through to the latest-release lookup below.
    $requestedVersion = $RequestedVersion
    if (-not $requestedVersion) {
        $callerVersion = Get-Variable -Name 'Version' -Scope 1 -ErrorAction SilentlyContinue
        if ($callerVersion -and $callerVersion.Value) {
            $requestedVersion = $callerVersion.Value
        }
    }

    $ocxHome = if ($env:OCX_HOME) { $env:OCX_HOME } else { Join-Path $env:USERPROFILE '.ocx' }
    Assert-SafeOcxHome -Path $ocxHome

    $target = Detect-Architecture
    Say "Detected platform: $target"

    if (-not $requestedVersion) {
        Say 'Fetching latest version...'
        $requestedVersion = Get-LatestVersion
    }

    # Character-blocklist stage FIRST: reject any version carrying a character
    # outside the semver-safe set. PowerShell's `-notmatch` is unanchored at the
    # end, so the prefix check below alone would accept "1.2.3;evil". Mirror
    # install.sh, which rejects '[^0-9A-Za-z.+-]' before the prefix check.
    if ($requestedVersion -match '[^0-9A-Za-z.+-]') {
        Err "Invalid version format: $requestedVersion (expected semver like 1.2.3 or 1.0.0-rc.1)" 2
    }

    if ($requestedVersion -notmatch '^\d+\.\d+\.\d+') {
        Err "Invalid version format: $requestedVersion (expected semver like 1.2.3)" 2
    }

    # Canonical bin dir (real on-disk store layout).
    $installBinDir = Join-Path $ocxHome $OcxBinSubPath

    $oldVersion = ''
    $existingBin = Join-Path $installBinDir 'ocx.exe'
    if (Test-Path $existingBin) {
        # Best-effort upgrade-messaging probe. A broken/blocked existing binary
        # must not abort the reinstall, so swallow the failure and treat the old
        # version as unknown (empty). Note it under -Verbose for diagnostics.
        try { $oldVersion = & $existingBin version 2>$null }
        catch { Write-Verbose "Could not read existing ocx version: $($_.Exception.Message)" }
    }

    # Force / idempotent fast-path
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

        # Extract archive (zip-slip safe on PS 5.1+; see Expand-ZipSafely).
        $extractDir = Join-Path $tmpDir 'extracted'
        try {
            Expand-ZipSafely -Path (Join-Path $tmpDir $archive) -Destination $extractDir
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

        # PATH shadowing: warn if a different ocx.exe already exists on PATH.
        # Use OrdinalIgnoreCase (CWE-178 defence — incorrect case handling):
        # Windows file paths are case-insensitive at the OS layer, but the
        # default `String.StartsWith` is culture-sensitive (e.g. in Turkish
        # locale 'i' and 'I' don't match), which could miss the shadow check
        # and silently let an unrelated `ocx.exe` win on PATH.
        #
        # Anchor the prefix to a trailing path separator so a sibling directory
        # named '.ocx-evil\' or '.ocxbackup\' cannot pose as an in-tree binary
        # and suppress the warning. Without the trailing '\', StartsWith would
        # accept any directory that lexically begins with $ocxHome.
        $existingOcx = Get-Command ocx -ErrorAction SilentlyContinue
        $ocxHomePrefix = $ocxHome.TrimEnd('\') + '\'
        if ($existingOcx -and -not $existingOcx.Source.StartsWith($ocxHomePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Warn "An existing ocx was found at $($existingOcx.Source)"
            Warn 'The new install may be shadowed — check your PATH order.'
        }

        if (-not (Test-Path $ocxHome)) {
            New-Item -ItemType Directory -Path $ocxHome -Force | Out-Null
        }

        if ($OcxInstallSkipSelfInit) {
            # CI/GitLab path: drop the binary on PATH only. Skip the networked
            # bootstrap AND env-shim/self-activate generation. Profile
            # modification remains independently controlled by OCX_NO_MODIFY_PATH
            # below.
            Install-WithoutSelfInit -Bin $bin -OcxHome $ocxHome
            Say "Installed to $installBinDir\ocx.exe"
        }
        else {
            # Bootstrap: OCX installs itself into its own package store.
            # --select is a boolean "set as current" flag; the package id is
            # positional.
            Say 'Bootstrapping OCX into its own package store...'
            & $bin --remote package install --select "ocx.sh/ocx/cli:$requestedVersion"
            if ($LASTEXITCODE -ne 0) {
                Err "Bootstrap failed: 'ocx --remote package install --select ocx.sh/ocx/cli:$requestedVersion'`nEnsure ocx v$requestedVersion is published to the ocx.sh registry.`nTo skip the bootstrap step (offline / air-gapped installs), set OCX_INSTALL_SKIP_SELF_INIT=1." 6
            }
            Say "Installed to $installBinDir\ocx.exe"

            Create-EnvFile -OcxHome $ocxHome
        }

        # Profile modification (independently gated by OCX_NO_MODIFY_PATH).
        if ($OcxNoModifyPath) {
            Say 'Skipping profile modification (OCX_NO_MODIFY_PATH).'
        }
        else {
            try {
                if ($OcxInstallSkipSelfInit) {
                    # No env.ps1 shim exists in skip-self-init mode; prepend the
                    # bin dir directly via the profile block.
                    Modify-ProfileBinaryOnly -OcxHome $ocxHome
                }
                else {
                    Modify-Profile -OcxHome $ocxHome
                }
            }
            catch {
                Warn "Failed to modify PowerShell profile: $($_.Exception.Message)"
                Warn 'You can manually add OCX to your profile by running:'
                Warn "  Add-Content `$PROFILE '`. `"$ocxHome\env.ps1`"'"
            }
        }

        Export-GithubPath -OcxHome $ocxHome

        if (-not $OcxInstallSkipSelfInit) {
            Print-Success -InstalledVersion $requestedVersion -OldVersion $oldVersion
        }

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
        $ghBinPath = Join-Path $OcxHome $OcxBinSubPath
        try {
            Add-Content -Path $env:GITHUB_PATH -Value $ghBinPath
        }
        catch {
            Warn 'Failed to write to $GITHUB_PATH.'
        }
    }
}

# Drive version resolution from the -Version script parameter. Passing it
# explicitly here is what makes the param load-bearing (README documents
# `-Version`); Main falls back to the caller-scope idiom / latest lookup when
# it is empty.
Main -RequestedVersion $Version
