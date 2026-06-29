# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0](https://github.com/ocx-sh/setup.ocx.sh/releases/tag/v0.1.0) — 2026-06-29

### Added

- Bootstrap setup.ocx.sh as installer-script host by @michael-herwig ([1bf221a](https://github.com/ocx-sh/setup.ocx.sh/commit/1bf221af89090b4c50012adb47252138a7dd6070))
- Reconcile installers with real OCX CLI and harden by @michael-herwig ([f621247](https://github.com/ocx-sh/setup.ocx.sh/commit/f621247b2711d1bc25bd591e524a4a5f708ea58b))
- Thin all-shell installers, dist.json manifest, vendored bats by @michael-herwig ([2f25bbc](https://github.com/ocx-sh/setup.ocx.sh/commit/2f25bbc8cd1caf0cbbd96d92355e832abbb22a7a))
- **install:** Make install.ps1 cross-platform (Windows + Linux + macOS) by @michael-herwig ([a38cc69](https://github.com/ocx-sh/setup.ocx.sh/commit/a38cc695f5edc68be811d43b92a48e3e5d7fa7e2))

### Changed

- **publish:** Version-major installer URL layout (archive/latest/next) by @michael-herwig ([ff1ffa2](https://github.com/ocx-sh/setup.ocx.sh/commit/ff1ffa256e1c7265f38e72e347743596f2a5d565))

### Fixed

- **install:** Correct nu/elvish activation; add docker shell-axis tests by @michael-herwig ([e29b696](https://github.com/ocx-sh/setup.ocx.sh/commit/e29b696d4c713d47e2e428ff73f675057539f6fa))
- **install:** Use macOS bsdtar-compatible tar extraction flags by @michael-herwig ([6bd59b2](https://github.com/ocx-sh/setup.ocx.sh/commit/6bd59b2eb2dfa98c2d37bb30fedc039d04501687))
- **publish:** Make uploaded dist.json world-readable by @michael-herwig ([83c2744](https://github.com/ocx-sh/setup.ocx.sh/commit/83c274401bc4f88bb821caa00e7f9eddc55c3aae))
- **publish:** Create remote dirs with rsync --mkpath, not ssh mkdir by @michael-herwig ([0d9e3c1](https://github.com/ocx-sh/setup.ocx.sh/commit/0d9e3c13bbffe132d80d6bd4c78f37b8945f4c50))
