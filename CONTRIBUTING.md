# Contributing to NotchMate

Thanks for wanting to help! NotchMate is a small, friendly project — every bug report, idea and pull request matters.

> Русскоязычным участникам: issues и pull request'ы можно писать по-русски.

## Good first contributions

- **English localization.** The UI is in Russian; moving strings into a `Localizable.xcstrings` catalog and translating them is the most wanted change.
- **Intel Macs.** Releases are arm64 only; a universal build is welcome.
- **New companion animations**, bug fixes and small UI polish.

## Getting started

```bash
git clone --recursive https://github.com/aleksandr-developer1/notchmate.git
cd notchmate
./build.sh install
```

Requirements: macOS 14+, Apple Silicon, Xcode or Command Line Tools with Swift 5.10+. See the [README](README.md#build) for signing and permissions.

## Pull requests

1. Open an issue first for anything bigger than a small fix, so we can agree on the approach.
2. Keep the change focused: one feature or fix per PR.
3. Match the surrounding code: SwiftUI views next to their service, one folder per feature in `Sources/NotchMate`.
4. Make sure `swift build` passes without warnings and describe how you tested the change.
5. Never commit personal data, tokens or build output.

## Reporting bugs

Use the **Bug report** template and include your macOS version, Mac model and what you expected to happen. Logs from Console.app (filter by `NotchMate`) help a lot.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
