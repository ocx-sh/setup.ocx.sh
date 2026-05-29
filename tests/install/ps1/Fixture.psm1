# Shared Pester fixtures for pwsh/install.ps1.
# Imported via `Import-Module $PSScriptRoot/Fixture.psm1 -Force` from each suite.
#
# This is the PowerShell analogue of tests/install/helpers/server.bash: it
# builds a fake GitHub-release tree (archive + sha256.sum + api/.../latest) and
# spins a `python3 -m http.server` against it so the installer can be driven
# end-to-end without network access.
#
# Layout notes (load-bearing):
#   * The release archive is built FLAT (ocx.exe at the archive root, no
#     ocx-<target>/ wrapper dir). This matches the real cargo-dist release
#     layout (verified in AUDIT-phase-a Appendix A/F) AND is the only layout the
#     installer can locate on a non-Windows pwsh host: Join-Path treats '\' as a
#     literal on Linux, so the nested candidate "ocx-<target>\ocx.exe" never
#     matches an extracted "ocx-<target>/ocx.exe" there. Flat keeps these suites
#     meaningful on ubuntu-pwsh and faithful to production on windows-latest.
#   * The fixture target is always x86_64-pc-windows-msvc — Detect-Architecture
#     returns that for an X64 host regardless of OS (it keys off
#     RuntimeInformation.OSArchitecture / PROCESSOR_ARCHITECTURE, not $IsWindows).

$script:Target = 'x86_64-pc-windows-msvc'

function Get-FixtureTarget {
    return $script:Target
}

# Wait for `python -m http.server 0` to report its ephemeral port. The port line
# can land on either stdout or stderr depending on the CPython version, and on
# Linux pwsh Start-Process forbids redirecting both streams to the SAME file, so
# we always pass two distinct log files and scan both.
function Wait-FixturePort {
    param(
        [Parameter(Mandatory)][string]$OutLog,
        [Parameter(Mandatory)][string]$ErrLog
    )
    for ($i = 0; $i -lt 100; $i++) {
        foreach ($lf in @($ErrLog, $OutLog)) {
            if (Test-Path $lf) {
                $content = Get-Content $lf -Raw -ErrorAction SilentlyContinue
                if ($content -match 'port (\d+)') { return $Matches[1] }
            }
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

# Resolve the python interpreter. Windows runners expose `python`; Linux runners
# (and this dev box) expose `python3`. Prefer python3, fall back to python.
function Get-PythonExe {
    foreach ($name in @('python3', 'python')) {
        if (Get-Command $name -ErrorAction SilentlyContinue) { return $name }
    }
    throw 'No python3/python interpreter found on PATH for the fixture server.'
}

# Write the stub `ocx.exe` into $BuildDir.
#   - default: a no-op binary that prints "0.0.0" for `version`.
#   - $BootstrapArgvLog: capture the bootstrap argv to this file and exit 9, so a
#     suite can assert the exact `--remote package install --select
#     ocx.sh/ocx/cli:<ver>` argv and the exit-6 contract. (Only executable on a
#     real Windows host or via shebang on Linux — see suite-level -Skip gates.)
function New-OcxStub {
    param(
        [Parameter(Mandatory)][string]$BuildDir,
        [string]$BootstrapArgvLog
    )
    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
    $stubPath = Join-Path $BuildDir 'ocx.exe'

    if ($BootstrapArgvLog) {
        # POSIX-shebang stub: records "$*" to the argv log then exits 9 so the
        # installer surfaces exit code 6. On Windows this same file is invoked
        # as ocx.exe; on Linux the shebang + a chmod by the caller make it run.
        $body = "#!/bin/sh`n" +
                "printf '%s' `"`$*`" > '$BootstrapArgvLog'`n" +
                "exit 9`n"
    }
    else {
        $body = "#!/bin/sh`n" +
                "if [ `"`$1`" = version ]; then echo 0.0.0; fi`n" +
                "exit 0`n"
    }
    [System.IO.File]::WriteAllText($stubPath, $body)
    return $stubPath
}

# Build the fake release tree under $Root and return a hashtable describing it.
# $TamperChecksum forces a wrong sha256 (exit-4 path). $BootstrapArgvLog routes
# through New-OcxStub's capture stub.
function New-OcxFixture {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$TamperChecksum,
        [string]$BootstrapArgvLog
    )

    $target = $script:Target
    $build = Join-Path $Root 'build'
    New-OcxStub -BuildDir $build -BootstrapArgvLog $BootstrapArgvLog | Out-Null

    $srvDir = Join-Path $Root 'srv/releases/download/v0.0.0'
    New-Item -ItemType Directory -Path $srvDir -Force | Out-Null
    $apiDir = Join-Path $Root 'srv/api/repos/ocx-sh/ocx/releases'
    New-Item -ItemType Directory -Path $apiDir -Force | Out-Null

    # FLAT archive: compress the *contents* of $build, not $build itself.
    $archive = "ocx-$target.zip"
    $archivePath = Join-Path $srvDir $archive
    Compress-Archive -Path (Join-Path $build '*') -DestinationPath $archivePath -Force

    if ($TamperChecksum) {
        $hash = '0' * 64
    }
    else {
        $hash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLower()
    }
    "$hash  $archive" | Set-Content -Path (Join-Path $srvDir 'sha256.sum') -Encoding ASCII -NoNewline

    '{"tag_name":"v0.0.0","name":"v0.0.0"}' |
        Set-Content -Path (Join-Path $apiDir 'latest') -Encoding ASCII

    return @{
        Root    = $Root
        SrvRoot = (Join-Path $Root 'srv')
        Target  = $target
        Archive = $archive
    }
}

# Spin a python http.server against $SrvRoot and return @{ Process; Port;
# BaseUrl; ApiUrl }. Caller stops the process in its teardown.
#
# We do NOT use the bare `python -m http.server` (as server.bash does) because
# that guesses MIME from the file extension: the extensionless `latest` release
# file is served as application/octet-stream, which makes Invoke-WebRequest
# return a byte[] (not a string), and Get-LatestVersion's regex never matches.
# The REAL GitHub API serves application/json, so we launch a one-file server
# that forces application/json on the `latest` endpoint — faithful to
# production and identical across windows-latest / ubuntu-pwsh.
function Start-FixtureServer {
    param([Parameter(Mandatory)][string]$SrvRoot)

    $python = Get-PythonExe
    $parent = Split-Path $SrvRoot -Parent
    $outLog = Join-Path $parent 'srv.out.log'
    $errLog = Join-Path $parent 'srv.err.log'

    $serverPy = Join-Path $parent 'fixture-server.py'
    $pyBody = @'
import http.server, socketserver

class Handler(http.server.SimpleHTTPRequestHandler):
    def guess_type(self, path):
        # GitHub's releases API responds with JSON; emulate that for the
        # extensionless `latest` file so Invoke-WebRequest yields a string.
        if path.endswith('latest'):
            return 'application/json'
        return super().guess_type(path)

with socketserver.TCPServer(('127.0.0.1', 0), Handler) as httpd:
    print('Serving HTTP on 127.0.0.1 port %d' % httpd.server_address[1], flush=True)
    httpd.serve_forever()
'@
    [System.IO.File]::WriteAllText($serverPy, $pyBody)

    $proc = Start-Process -FilePath $python `
        -ArgumentList '-u', $serverPy `
        -WorkingDirectory $SrvRoot `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError $errLog `
        -PassThru

    $port = Wait-FixturePort -OutLog $outLog -ErrLog $errLog
    if (-not $port) {
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        throw "Failed to start fixture server (logs: $outLog / $errLog)"
    }

    return @{
        Process = $proc
        Port    = $port
        BaseUrl = "http://127.0.0.1:$port/releases/download"
        ApiUrl  = "http://127.0.0.1:$port/api/repos/ocx-sh/ocx/releases"
    }
}

function Stop-FixtureServer {
    param($Server)
    if ($Server -and $Server.Process -and -not $Server.Process.HasExited) {
        Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue
    }
}

# Canonical OCX bin dir under $OcxHome — the real on-disk store layout
# (symlinks/ocx.sh/ocx/cli/current/content/bin). Mirrors install.ps1
# $OcxBinSubPath. Uses Join-Path so the separator matches the host.
function Get-ExpectedBinDir {
    param([Parameter(Mandatory)][string]$OcxHome)
    return (Join-Path $OcxHome 'symlinks/ocx.sh/ocx/cli/current/content/bin')
}

Export-ModuleMember -Function `
    Get-FixtureTarget, New-OcxFixture, New-OcxStub, Start-FixtureServer, `
    Stop-FixtureServer, Get-ExpectedBinDir, Wait-FixturePort, Get-PythonExe
