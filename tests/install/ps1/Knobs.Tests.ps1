#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Pester tests for pwsh/install.ps1 env-var knobs and exit codes.
# Mirrors the Bats suite in ../env-knobs.bats.

BeforeAll {
    $script:InstallPs1 = Join-Path $PSScriptRoot '..\..\..\pwsh\install.ps1'
    $script:Target = 'x86_64-pc-windows-msvc'
    $script:FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-install-test-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"

    # Build fixture: stub ocx.exe (a .cmd that prints version), zipped, with sha256.
    $build = Join-Path $FixtureRoot "build\ocx-$Target"
    New-Item -ItemType Directory -Path $build -Force | Out-Null
    $stubCmd = Join-Path $build 'ocx.cmd'
    @"
@echo off
if "%1"=="version" echo 0.0.0
"@ | Set-Content -Path $stubCmd -Encoding ASCII
    # Pwsh archive expects ocx.exe; rename .cmd → .exe (we never execute it
    # on Windows in skip-bootstrap mode beyond optional smoke test which
    # OCX_INSTALL_NO_BIN_SMOKETEST=1 disables).
    Move-Item $stubCmd (Join-Path $build 'ocx.exe')

    $srvDir = Join-Path $FixtureRoot 'srv\releases\download\v0.0.0'
    New-Item -ItemType Directory -Path $srvDir -Force | Out-Null
    $apiDir = Join-Path $FixtureRoot 'srv\api\repos\ocx-sh\ocx\releases'
    New-Item -ItemType Directory -Path $apiDir -Force | Out-Null

    $archivePath = Join-Path $srvDir "ocx-$Target.zip"
    Compress-Archive -Path $build -DestinationPath $archivePath -Force

    $hash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLower()
    "$hash  ocx-$Target.zip" | Set-Content -Path (Join-Path $srvDir 'sha256.sum') -Encoding ASCII

    '{"tag_name":"v0.0.0"}' | Set-Content -Path (Join-Path $apiDir 'latest') -Encoding ASCII

    # Start Python http.server (assumes python3 on PATH on Windows runners).
    $script:ServerLog = Join-Path $FixtureRoot 'srv.log'
    $srvRoot = Join-Path $FixtureRoot 'srv'
    $script:ServerProc = Start-Process -FilePath 'python' `
        -ArgumentList '-u', '-m', 'http.server', '0' `
        -WorkingDirectory $srvRoot `
        -RedirectStandardOutput $ServerLog `
        -RedirectStandardError $ServerLog `
        -PassThru -NoNewWindow

    $script:Port = $null
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-Path $ServerLog) {
            $line = Get-Content $ServerLog -Raw
            if ($line -match 'port (\d+)') { $script:Port = $Matches[1]; break }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $Port) { throw "Failed to start fixture server (log: $ServerLog)" }

    $script:BaseUrl = "http://127.0.0.1:$Port/releases/download"
    $script:ApiUrl = "http://127.0.0.1:$Port/api/repos/ocx-sh/ocx/releases"
}

AfterAll {
    if ($ServerProc -and -not $ServerProc.HasExited) {
        Stop-Process -Id $ServerProc.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $FixtureRoot) {
        Remove-Item -Recurse -Force $FixtureRoot -ErrorAction SilentlyContinue
    }
}

Describe 'install.ps1 env knobs' {
    BeforeEach {
        $script:OcxHome = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-test-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $env:OCX_HOME = $OcxHome
        $env:OCX_NO_MODIFY_PATH = '1'
        $env:OCX_INSTALL_SKIP_BOOTSTRAP = '1'
        $env:OCX_INSTALL_NO_BIN_SMOKETEST = '1'
        $env:OCX_INSTALL_BASE_URL = $BaseUrl
        $env:OCX_INSTALL_API_URL = $ApiUrl
        Remove-Item Env:GITHUB_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_FORMAT_URL -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_CHECKSUM_FORMAT_URL -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_PRINT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_QUIET -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_FORCE -ErrorAction SilentlyContinue
    }

    AfterEach {
        if (Test-Path $OcxHome) { Remove-Item -Recurse -Force $OcxHome -ErrorAction SilentlyContinue }
    }

    It 'installs from env-overridden URLs' {
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' | Out-Null
        $LASTEXITCODE | Should -Be 0
        $bin = Join-Path $OcxHome 'symlinks\ocx.sh\ocx\current\bin\ocx.exe'
        Test-Path $bin | Should -BeTrue
    }

    It 'PRINT_PATH=1 emits bin dir as final stdout line' {
        $env:OCX_INSTALL_PRINT_PATH = '1'
        $env:OCX_INSTALL_QUIET = '1'
        $out = & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
        $LASTEXITCODE | Should -Be 0
        $expected = Join-Path $OcxHome 'symlinks\ocx.sh\ocx\current\bin'
        ($out | Select-Object -Last 1) | Should -Be $expected
    }

    It 'invalid version → exit 2' {
        & pwsh -NoProfile -File $InstallPs1 -Version 'foo;rm' 2>$null
        $LASTEXITCODE | Should -Be 2
    }

    It '404 → exit 3' {
        $env:OCX_INSTALL_BASE_URL = "http://127.0.0.1:$Port/no-such"
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
        $LASTEXITCODE | Should -Be 3
    }

    It 'checksum mismatch → exit 4' {
        # Reuse fixture but override sha256 file via a tampered tree.
        $tamper = Join-Path $FixtureRoot 'tamper'
        Copy-Item -Recurse -Force (Join-Path $FixtureRoot 'srv') $tamper
        $sumPath = Join-Path $tamper 'releases\download\v0.0.0\sha256.sum'
        ('0' * 64 + "  ocx-$Target.zip") | Set-Content -Path $sumPath -Encoding ASCII
        # Spin a sub-server
        $tlog = Join-Path $FixtureRoot 't.log'
        $tproc = Start-Process -FilePath 'python' `
            -ArgumentList '-u', '-m', 'http.server', '0' `
            -WorkingDirectory $tamper `
            -RedirectStandardOutput $tlog -RedirectStandardError $tlog `
            -PassThru -NoNewWindow
        $tport = $null
        for ($i = 0; $i -lt 100; $i++) {
            if (Test-Path $tlog) {
                $l = Get-Content $tlog -Raw
                if ($l -match 'port (\d+)') { $tport = $Matches[1]; break }
            }
            Start-Sleep -Milliseconds 100
        }
        try {
            $env:OCX_INSTALL_BASE_URL = "http://127.0.0.1:$tport/releases/download"
            $env:OCX_INSTALL_API_URL = "http://127.0.0.1:$tport/api/repos/ocx-sh/ocx/releases"
            & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
            $LASTEXITCODE | Should -Be 4
        }
        finally {
            Stop-Process -Id $tproc.Id -Force -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force $tamper -ErrorAction SilentlyContinue
        }
    }

    It 'idempotent fast-path returns success without re-download' {
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' | Out-Null
        $LASTEXITCODE | Should -Be 0
        $env:OCX_INSTALL_PRINT_PATH = '1'
        $env:OCX_INSTALL_QUIET = '1'
        $out = & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
        $LASTEXITCODE | Should -Be 0
        $expected = Join-Path $OcxHome 'symlinks\ocx.sh\ocx\current\bin'
        ($out | Select-Object -Last 1) | Should -Be $expected
    }
}
