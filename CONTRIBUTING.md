# Contributing to NotchMate

Thanks for wanting to help! NotchMate is a small, friendly project — every bug report, idea and pull request matters.

> Русскоязычным участникам: issues и pull request'ы можно писать по-русски.

## Good first contributions

- **Translations.** NotchMate ships in 8 languages. Fixing a clumsy phrase or adding a new language is a great first PR — see below.
- **Intel Macs.** Releases are arm64 only; a universal build is welcome.
- **New companion animations**, bug fixes and small UI polish.

## Getting started

```bash
git clone --recursive https://github.com/aleksandr-developer1/notchmate.git
cd notchmate
./build.sh install
```

Requirements: macOS 14+, Apple Silicon, Xcode or Command Line Tools with Swift 5.10+. See the [README](README.md#build) for signing and permissions.

## Translations

All UI strings live in [`Resources/Localizable.xcstrings`](Resources/Localizable.xcstrings) (permission prompts in `Resources/InfoPlist.xcstrings`). The source language is Russian: every key is the Russian text, and each language has its own value. You can edit the catalog in Xcode or as JSON.

- Keep format specifiers (`%@`, `%lld`, `%%`) and their count; reorder with positions like `%2$@` if your grammar needs it.
- Keep Markdown (`**bold**`), emoji and leading/trailing spaces.
- **New language:** add its values to both catalogs, add the code to `CFBundleLocalizations` in `Resources/Info.plist` and to `AppLanguage.supported` in `Sources/NotchMate/Core/AppLanguage.swift`.
- **New strings in code:** write UI text as `String(localized: "…")`, then refresh the catalog:
  ```bash
  swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc /tmp/strings
  xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata /tmp/strings/*.stringsdata
  ```
- Prompts sent to AI models stay in Russian on purpose: they end with an instruction to answer in the UI language.

## Pull requests

1. Open an issue first for anything bigger than a small fix, so we can agree on the approach.
2. Keep the change focused: one feature or fix per PR.
3. Match the surrounding code: SwiftUI views next to their service, one folder per feature in `Sources/NotchMate`.
4. Make sure `swift build` passes without warnings and describe how you tested the change.
5. Never commit personal data, tokens or build output.

## Reporting bugs

Use the **Bug report** template and include your macOS version, Mac model and what you expected to happen. Logs from Console.app (filter by `NotchMate`) help a lot.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
