#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Pester coverage for the numbered exit-code contract of pwsh/install.ps1.
# Mirrors ../exit-codes.bats scenario for scenario.
#
#   Exit 2 (arg/env validation) and 3/4 (network/checksum) are covered in
#   Knobs.Tests.ps1, matching the Bats split (env-knobs.bats owns 2/3/4).
#   Exit 7 (unsupported platform) cannot be triggered on an X64 host —
#   Detect-Architecture only emits code 7 for X86/Arm/unknown — so it is
#   asserted by static reasoning here and exercised for real by tests/docker/.
#
# This suite focuses on:
#   * exit 5 — archive extraction failure (corrupt zip, and a zip with no
#     ocx.exe inside)
#   * exit 6 — bootstrap failure, INCLUDING an assertion of the exact bootstrap
#     argv ('--remote package install --select ocx.sh/ocx/cli:<ver>').

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Fixture.psm1') -Force
    $script:InstallPs1 = Join-Path $PSScriptRoot '..\..\..\pwsh\install.ps1'
    $script:Target = Get-FixtureTarget
}

Describe 'install.ps1 exit codes' {
    BeforeEach {
        $script:CaseRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $CaseRoot -Force | Out-Null
        $script:OcxHome = Join-Path $CaseRoot 'home'
        $env:OCX_HOME = $OcxHome
        $env:OCX_NO_MODIFY_PATH = '1'
        $env:OCX_INSTALL_SKIP_SELF_INIT = '1'
        $env:OCX_INSTALL_NO_BIN_SMOKETEST = '1'
        $env:OCX_INSTALL_QUIET = '1'
        Remove-Item Env:GITHUB_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_FORMAT_URL -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_CHECKSUM_FORMAT_URL -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_PRINT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:OCX_INSTALL_FORCE -ErrorAction SilentlyContinue
    }

    AfterEach {
        if (Test-Path $CaseRoot) { Remove-Item -Recurse -Force $CaseRoot -ErrorAction SilentlyContinue }
    }

    # Mirrors exit-codes.bats: "exit 5: corrupt archive (bad xz) fails to extract".
    # Build a valid fixture, then overwrite the archive bytes with garbage and
    # recompute the matching sha256 so we bypass the checksum gate (exit 4) and
    # reach the extraction failure (exit 5).
    It 'exit 5: corrupt archive fails to extract' {
        $fx = New-OcxFixture -Root $CaseRoot
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        try {
            $archivePath = Join-Path $fx.SrvRoot "releases/download/v0.0.0/$($fx.Archive)"
            [System.IO.File]::WriteAllText($archivePath, 'not a real zip archive')
            $hash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLower()
            "$hash  $($fx.Archive)" |
                Set-Content -Path (Join-Path $fx.SrvRoot 'releases/download/v0.0.0/sha256.sum') -Encoding ASCII -NoNewline

            $env:OCX_INSTALL_BASE_URL = $srv.BaseUrl
            $env:OCX_INSTALL_API_URL = $srv.ApiUrl
            & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
            $LASTEXITCODE | Should -Be 5
        }
        finally {
            Stop-FixtureServer -Server $srv
        }
    }

    # Mirrors exit-codes.bats: "exit 5: archive missing ocx binary".
    # A well-formed zip whose only entry is a non-ocx file: extraction succeeds
    # but no ocx.exe is found -> exit 5.
    It 'exit 5: archive missing ocx binary' {
        $srvDir = Join-Path $CaseRoot 'srv/releases/download/v0.0.0'
        New-Item -ItemType Directory -Path $srvDir -Force | Out-Null
        $apiDir = Join-Path $CaseRoot 'srv/api/repos/ocx-sh/ocx/releases'
        New-Item -ItemType Directory -Path $apiDir -Force | Out-Null

        $emptyBuild = Join-Path $CaseRoot 'empty-build'
        New-Item -ItemType Directory -Path $emptyBuild -Force | Out-Null
        'README' | Set-Content -Path (Join-Path $emptyBuild 'README.txt') -Encoding ASCII

        $archive = "ocx-$Target.zip"
        $archivePath = Join-Path $srvDir $archive
        Compress-Archive -Path (Join-Path $emptyBuild '*') -DestinationPath $archivePath -Force
        $hash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLower()
        "$hash  $archive" | Set-Content -Path (Join-Path $srvDir 'sha256.sum') -Encoding ASCII -NoNewline
        '{"tag_name":"v0.0.0","name":"v0.0.0"}' | Set-Content -Path (Join-Path $apiDir 'latest') -Encoding ASCII

        $srv = Start-FixtureServer -SrvRoot (Join-Path $CaseRoot 'srv')
        try {
            $env:OCX_INSTALL_BASE_URL = $srv.BaseUrl
            $env:OCX_INSTALL_API_URL = $srv.ApiUrl
            & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
            $LASTEXITCODE | Should -Be 5
        }
        finally {
            Stop-FixtureServer -Server $srv
        }
    }

    # Mirrors exit-codes.bats:
    #   "exit 6: bootstrap failure when stub --remote returns nonzero".
    # The bootstrap branch only runs when SKIP_SELF_INIT is unset, and it must
    # EXECUTE the extracted ocx.exe. Extracted files have no +x bit on Linux
    # (install.ps1 never chmods — Windows doesn't need it), so the native
    # invocation can only succeed on a real Windows host. Skip elsewhere.
    It 'exit 6: bootstrap failure when ocx --remote package install returns nonzero' -Skip:(-not $IsWindows) {
        $argvLog = Join-Path $CaseRoot 'argv.log'
        $fx = New-OcxFixture -Root $CaseRoot -BootstrapArgvLog $argvLog
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        try {
            Remove-Item Env:OCX_INSTALL_SKIP_SELF_INIT -ErrorAction SilentlyContinue
            $env:OCX_INSTALL_BASE_URL = $srv.BaseUrl
            $env:OCX_INSTALL_API_URL = $srv.ApiUrl
            & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
            $LASTEXITCODE | Should -Be 6
        }
        finally {
            Stop-FixtureServer -Server $srv
        }
    }

    # Asserts the EXACT bootstrap argv the corrected installer must invoke:
    #   ocx --remote package install --select ocx.sh/ocx/cli:0.0.0
    # This is the runtime form of the regression guard for the hallucinated
    # `ocx --remote install --select ocx.sh/ocx:VER` form. It must EXECUTE the
    # extracted ocx.exe to capture its argv, and install.ps1 extracts into a
    # private temp dir and never chmod +x's the result (Windows needs no +x).
    # The .NET extract path drops the archive's unix mode, so the extracted stub
    # cannot be made executable from the test side — `& $bin` therefore only runs
    # on a real Windows host. Skipped elsewhere; the cross-OS guard for this
    # contract is the static-source assertion below, which RUNS on every runner.
    It 'bootstrap invokes "package install --select ocx.sh/ocx/cli:<version>"' -Skip:(-not $IsWindows) {
        $argvLog = Join-Path $CaseRoot 'argv.log'
        $fx = New-OcxFixture -Root $CaseRoot -BootstrapArgvLog $argvLog
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        try {
            Remove-Item Env:OCX_INSTALL_SKIP_SELF_INIT -ErrorAction SilentlyContinue
            $env:OCX_INSTALL_BASE_URL = $srv.BaseUrl
            $env:OCX_INSTALL_API_URL = $srv.ApiUrl
            & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
            $LASTEXITCODE | Should -Be 6
            Test-Path $argvLog | Should -BeTrue
            $argv = (Get-Content $argvLog -Raw).Trim()
            $argv | Should -Be '--remote package install --select ocx.sh/ocx/cli:0.0.0'
        }
        finally {
            Stop-FixtureServer -Server $srv
        }
    }

    # Cross-OS bootstrap-argv contract guard. The two tests above can only
    # EXECUTE the captured-argv stub on Windows (Linux extract lacks +x and
    # install.ps1 never chmods), so on ubuntu-pwsh — where CLAUDE.md says Pester
    # also runs — they SKIP and give NO red signal. This static assertion runs
    # unconditionally on every runner: it reads the install.ps1 SOURCE and pins
    # the bootstrap invocation to the real ocx 0.3.1 form, failing RED the moment
    # anyone regresses to the hallucinated `--remote install --select
    # ocx.sh/ocx:VER` (missing the `package` verb and the `/cli` package segment).
    It 'bootstrap source pins "--remote package install --select ocx.sh/ocx/cli:" (no hallucinated form)' {
        $src = Get-Content $InstallPs1 -Raw
        $src | Should -BeLike '*--remote package install --select ocx.sh/ocx/cli:*'
        $src | Should -Not -BeLike '*--remote install --select ocx.sh/ocx:*'
    }
}
