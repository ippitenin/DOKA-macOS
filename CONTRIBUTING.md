# Contributing to DOKA for macOS

<p><a href="CONTRIBUTING.ru.md">Русская версия</a></p>

Thanks for taking an interest. This is a small project with a few firm conventions — most
of them exist because something broke once. Please read this before opening a pull request.

## Getting set up

You need **macOS 15 or newer and Xcode 26 or newer**. The package declares
`swift-tools-version: 5.9`, but one of its dependencies requires Swift 6.2 and the Liquid
Glass APIs need the macOS 26 SDK — on an older toolchain the build fails while resolving
dependencies, before a single file is compiled.

```bash
git clone https://github.com/ippitenin/DOKA-macOS.git
cd DOKA-macOS/DOKA-app
swift build                # quick compile check
scripts/build-shaders.sh   # Metal shaders of the recording panel (build.sh runs it for you)
./run.sh                   # release build, sign, install to ~/Applications, launch
```

`./build.sh` signs with a self-signed **“DOKA Dev”** certificate — see
[`scripts/make-dev-cert.md`](DOKA-app/scripts/make-dev-cert.md). Note that re-signing
resets macOS TCC permissions, so you will be re-granting microphone and accessibility
access fairly often while developing.

Architecture, invariants and the reasoning behind the odd-looking bits are documented in
[`CLAUDE.md`](CLAUDE.md). It is worth reading the section relevant to your change — many
“obvious improvements” have already been tried and reverted.

## Verification gates

The pure logic is covered by tests in `Tests/DOKATests` — 531 checks that run in
under a second. Everything else (audio capture, pasting, Keychain, the recorder panels)
needs a real Mac with real permissions, so it is verified by hand. Five gates:

1. `swift build` — must finish with **no warnings**.
2. `swift test` — all green. Add tests for any pure logic you touch.
   Touching `Shaders/*.metal`? Run `scripts/build-shaders.sh` first: SwiftPM does not compile
   `.metal`, and without that step the build silently keeps the previous shader.
3. `plutil -lint` on both `Localizable.strings` files (and both `InfoPlist.strings` if you
   touched them). `swift build` does **not** validate `.strings` syntax — a broken file
   compiles fine and fails at runtime.
4. `./build.sh` — the release build must sign successfully.
5. A manual smoke pass over whatever you touched. `CLAUDE.md` lists what to check per area.

**Gates 1–3 run automatically on every pull request** (`.github/workflows/build.yml`).
Run them locally before pushing to get the answer in seconds instead of minutes:

```bash
swift build
swift test
./scripts/check-localization.sh
```

`check-localization.sh` verifies that the Russian and English key sets match, that
placeholders (`%@`, `%ld`, …) agree between them, that every key used via `L(...)` exists,
and that no dead strings accumulate. If you add a key that is assembled dynamically, add
its prefix to `DYNAMIC_PREFIXES` in the script — otherwise it will be reported as dead.

Gates 4 and 5 stay manual: CI has no signing certificate and cannot click through the app.

One trap when writing tests: anything that goes through `L(...)` — speaker display names,
role validation messages — depends on the bundle language. Assert on structure or numbers,
not on a particular translation.

## Conventions

- **Code and comments are written in Russian.** Keep new code consistent with what is
  already there.
- **Every interface string goes through `L("key")`**, and the key must exist in *both*
  `Sources/DOKA/Resources/ru.lproj/Localizable.strings` and `en.lproj/`. No hardcoded
  user-facing text.
- **The design system is the source of truth.** Colours, radii, spacing and animations come
  from the `DS` tokens in `UI/DesignSystem/`; glass surfaces go through `glassSurface()`.
  Do not hardcode colours or magic numbers in new UI.
- **Dependency pins are deliberate — do not loosen them, and never commit the result of a
  blind `swift package update`.** Each of the three pins guards the universal (arm64 +
  x86_64) release, which only `./build.sh` exercises — `swift build` alone will not catch a
  regression here.
  - **WhisperKit stays on the 0.18.x line.** In 1.x two executable products share a target
    and the universal build fails with “duplicate key found”.
  - **FluidAudio is pinned `exact: "0.15.5"`.** Its “patch” releases are not patches: 0.15.7
    adds a binary `NemoTextProcessing.xcframework` on which the universal build dies with
    `ld: library not found for -ltext_processing_rs`. A version range does not protect you
    here — that is why the pin is exact.
  - **llama.cpp is a `binaryTarget` pinned to one release (`b10909`) by url + checksum.**
    Upstream ships several releases a day and changes the C API without semver, and the
    macOS slice must be `macos-arm64_x86_64`. Moving it means a new checksum, a full
    `./build.sh` and a smoke pass over AI analysis.

  `Package.swift` carries the full reasoning next to each pin — read it before changing one.
- Commits follow conventional commits with a Russian description: `feat:`, `fix:`, `docs:`,
  `chore:`.

## Reporting bugs

Include your macOS version, your Mac’s chip (Apple Silicon or Intel), which recognition
service you were using, and what you expected to happen. If it involves a crash, Console
output helps.

**Never paste an API key into an issue.** Keys live in the Keychain precisely so they do not
end up in text.

## Contributor license grant

By submitting a pull request you agree that your contribution is licensed under GPL-3.0,
and you grant the project author (Ilya Pitenin) a non-exclusive, perpetual, worldwide,
royalty-free right to use, modify, sublicense and distribute your contribution, including
under a different license.

This keeps it possible to relicense the project or ship it through the Mac App Store
without collecting signatures from every past contributor. Your contribution remains
available under GPL-3.0 regardless — this grant adds a permission, it does not take one
away.
