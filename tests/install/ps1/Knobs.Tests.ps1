#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Pester tests for pwsh/install.ps1 env-var knobs and exit codes.
# Mirrors the Bats suite in ../env-knobs.bats, scenario for scenario.
#
# Runs meaningfully on both windows-latest and ubuntu-pwsh: the fixture archive
# is FLAT (see Fixture.psm1) so extraction + binary-location work on Linux too,
# and Detect-Architecture keys off RuntimeInformation (returns the windows-msvc
# target on any X64 host). Scenarios that require EXECUTING the extracted
# ocx.exe (bootstrap argv, exit-6, native version smoke) are gated to Windows;
# see -Skip notes and ../../.claude/rules/testing-pwsh.md.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Fixture.psm1') -Force
    $script:InstallPs1 = Join-Path $PSScriptRoot '..\..\..\pwsh\install.ps1'
    $script:Target = Get-FixtureTarget

    $script:FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-knobs-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    $fixture = New-OcxFixture -Root $FixtureRoot
    $script:Server = Start-FixtureServer -SrvRoot $fixture.SrvRoot
    $script:BaseUrl = $Server.BaseUrl
    $script:ApiUrl = $Server.ApiUrl
    $script:Port = $Server.Port
}

AfterAll {
    Stop-FixtureServer -Server $Server
    if (Test-Path $FixtureRoot) {
        Remove-Item -Recurse -Force $FixtureRoot -ErrorAction SilentlyContinue
    }
}

Describe 'install.ps1 env knobs' {
    BeforeEach {
        $script:OcxHome = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-test-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $env:OCX_HOME = $OcxHome
        $env:OCX_NO_MODIFY_PATH = '1'
        $env:OCX_INSTALL_SKIP_SELF_INIT = '1'
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

    # Mirrors env-knobs.bats:
    #   "default install via env-overridden URLs writes binary to OCX_HOME"
    It 'default install via env-overridden URLs writes binary to OCX_HOME' {
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' | Out-Null
        $LASTEXITCODE | Should -Be 0
        $bin = Join-Path (Get-ExpectedBinDir -OcxHome $OcxHome) 'ocx.exe'
        Test-Path $bin | Should -BeTrue
    }

    # Mirrors env-knobs.bats:
    #   "OCX_INSTALL_PRINT_PATH=1 emits bin dir as final stdout line"
    It 'OCX_INSTALL_PRINT_PATH=1 emits bin dir as final stdout line' {
        $env:OCX_INSTALL_PRINT_PATH = '1'
        $env:OCX_INSTALL_QUIET = '1'
        $out = & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
        $LASTEXITCODE | Should -Be 0
        $expected = Get-ExpectedBinDir -OcxHome $OcxHome
        ($out | Select-Object -Last 1) | Should -Be $expected
    }

    # Mirrors env-knobs.bats:
    #   "OCX_INSTALL_QUIET=1 suppresses stderr informational logs"
    It 'OCX_INSTALL_QUIET=1 suppresses stderr informational logs' {
        $env:OCX_INSTALL_QUIET = '1'
        $err = & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>&1 1>$null
        $LASTEXITCODE | Should -Be 0
        ($err | Out-String) | Should -Not -Match 'Detected platform'
    }

    # Mirrors env-knobs.bats:
    #   "stderr discipline: stdout is empty on success without PRINT_PATH"
    It 'stderr discipline: stdout is empty on success without PRINT_PATH' {
        $out = & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
        $LASTEXITCODE | Should -Be 0
        ($out | Where-Object { $_ -ne '' }) | Should -BeNullOrEmpty
    }

    # Mirrors env-knobs.bats: "404 -> exit code 3"
    It '404 -> exit code 3' {
        $env:OCX_INSTALL_BASE_URL = "http://127.0.0.1:$Port/no-such-path"
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
        $LASTEXITCODE | Should -Be 3
    }

    # Mirrors env-knobs.bats: "checksum mismatch -> exit code 4"
    It 'checksum mismatch -> exit code 4' {
        $tamperRoot = Join-Path $FixtureRoot "tamper-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $tf = New-OcxFixture -Root $tamperRoot -TamperChecksum
        $tsrv = Start-FixtureServer -SrvRoot $tf.SrvRoot
        try {
            $env:OCX_INSTALL_BASE_URL = $tsrv.BaseUrl
            $env:OCX_INSTALL_API_URL = $tsrv.ApiUrl
            & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
            $LASTEXITCODE | Should -Be 4
        }
        finally {
            Stop-FixtureServer -Server $tsrv
            Remove-Item -Recurse -Force $tamperRoot -ErrorAction SilentlyContinue
        }
    }

    # Mirrors env-knobs.bats: "invalid version -> exit code 2"
    It 'invalid version -> exit code 2' {
        & pwsh -NoProfile -File $InstallPs1 -Version 'foo;rm' 2>$null
        $LASTEXITCODE | Should -Be 2
    }

    # Mirrors env-knobs.bats: "unknown flag -> exit code 2"
    # The ps1 param() block is the analogue of the sh arg parser; an undeclared
    # parameter is a parameter-binding error. `pwsh -File` exits non-zero (and
    # never enters Main, so no #Requires/exit-2 path runs) — assert non-zero.
    It 'unknown flag -> nonzero exit (param binding error)' {
        & pwsh -NoProfile -File $InstallPs1 -Bogus 2>$null
        $LASTEXITCODE | Should -Not -Be 0
    }

    # Mirrors env-knobs.bats: "OCX_INSTALL_FORCE=1 reinstalls when same version is present".
    # The idempotent FAST-PATH branch probes the existing binary with
    # `& ocx.exe version`, which only runs on Windows (the extracted stub has no
    # +x bit on Linux). On Linux the second run does a full reinstall instead,
    # but the OBSERVABLE contract the Bats test asserts — exit 0 + identical
    # print-path on the second run, and exit 0 under FORCE — still holds, so the
    # scenario stays meaningful cross-platform.
    It 'OCX_INSTALL_FORCE=1 reinstalls when same version is present' {
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' | Out-Null
        $LASTEXITCODE | Should -Be 0
        $bin = Join-Path (Get-ExpectedBinDir -OcxHome $OcxHome) 'ocx.exe'
        Test-Path $bin | Should -BeTrue

        $env:OCX_INSTALL_PRINT_PATH = '1'
        $env:OCX_INSTALL_QUIET = '1'
        $out = & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
        $LASTEXITCODE | Should -Be 0
        ($out | Select-Object -Last 1) | Should -Be (Get-ExpectedBinDir -OcxHome $OcxHome)

        $env:OCX_INSTALL_FORCE = '1'
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    # Mirrors env-knobs.bats: "OCX_INSTALL_FORMAT_URL substitutes {version},{target},{ext},{tag}".
    It 'OCX_INSTALL_FORMAT_URL substitutes {version},{target},{ext},{tag}' {
        # Re-publish the fixture archive + checksum under a {version}-keyed
        # layout (no leading v) so the {version} placeholder is exercised.
        $custom = Join-Path $FixtureRoot "custom-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $cdir = Join-Path $custom "0.0.0/$Target"
        New-Item -ItemType Directory -Path $cdir -Force | Out-Null
        $srcDir = Join-Path $FixtureRoot 'srv/releases/download/v0.0.0'
        Copy-Item (Join-Path $srcDir "ocx-$Target.zip") (Join-Path $cdir "ocx-$Target.zip") -Force
        Copy-Item (Join-Path $srcDir 'sha256.sum') (Join-Path $cdir 'sums.txt') -Force
        $csrv = Start-FixtureServer -SrvRoot $custom
        try {
            $base = "http://127.0.0.1:$($csrv.Port)"
            $env:OCX_INSTALL_FORMAT_URL = "$base/{version}/{target}/ocx-{target}.{ext}"
            $env:OCX_INSTALL_CHECKSUM_FORMAT_URL = "$base/{version}/{target}/sums.txt"
            & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
        finally {
            Stop-FixtureServer -Server $csrv
            Remove-Item -Recurse -Force $custom -ErrorAction SilentlyContinue
        }
    }

    # Mirrors env-knobs.bats:
    #   "latest version resolves via OCX_INSTALL_API_URL override"
    It 'latest version resolves via OCX_INSTALL_API_URL override' {
        & pwsh -NoProfile -File $InstallPs1 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        $bin = Join-Path (Get-ExpectedBinDir -OcxHome $OcxHome) 'ocx.exe'
        Test-Path $bin | Should -BeTrue
    }
}
