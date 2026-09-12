// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DOKA",
    defaultLocalization: "en",   // язык отката для неподдерживаемых языков системы
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0"),
        // Локальные модели распознавания: Whisper через WhisperKit (Argmax OSS SDK)
        // и Parakeet V3 через FluidAudio. Обе — CoreML/ANE, macOS 14+.
        // ВНИМАНИЕ: линия 0.18.x — последняя без бага мультиарх-сборки SPM
        // (в 1.x два executable-продукта argmax-cli/whisperkit-cli делят один
        // таргет ArgmaxCLI → «duplicate key found» при --arch arm64 --arch x86_64).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", .upToNextMinor(from: "0.18.0")),
        // ТОЧНЫЙ пин, а не линия: у FluidAudio «патч» не означает патч. Между
        // 0.15.5 и 0.15.7 — 237 файлов и +28 000 строк, включая новые бэкенды
        // TTS/VAD/ASR и бинарный артефакт NemoTextProcessing.xcframework.
        //
        // Проверено на 0.15.7 (12.09.2026): debug собирается, 531 тест зелёный,
        // `swift build -c release --arch arm64` собирается, а
        // `swift build -c release --arch arm64 --arch x86_64` ПАДАЕТ:
        //     ld: library not found for -ltext_processing_rs
        // Срез `macos-arm64_x86_64` в самом xcframework есть — ломается
        // мультиарх-путь SwiftPM, ровно как у WhisperKit 1.x выше. А DOKA
        // раздаётся universal, то есть 0.15.7 для нас нерабочая.
        //
        // Прежний `.upToNextMinor(from: "0.15.5")` от этого не защищал: он
        // разрешает 0.15.7, и любой `swift package update` или резолв без
        // Package.resolved ломал бы релиз. Поднимать версию — только после
        // повторной проверки ИМЕННО universal-сборкой.
        //
        // Чего мы при этом не берём (полезное в 0.15.6/0.15.7):
        //   ce9f85e — проброс отмены в воркеры офлайнового диаризатора;
        //   df1417c, 3ebb285 — кластеризация и учёт лимита спикеров (у нас
        //                      используется `withSpeakers(exactly:)`);
        //   4dbf4f9 — отменённая закачка больше не стартует.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "DOKA",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                "LlamaFramework"
            ],
            path: "Sources/DOKA",
            resources: [.process("Resources")],
            // llama.framework — ДИНАМИЧЕСКИЙ фреймворк с install name
            // `@rpath/llama.framework/...`; build.sh кладёт его в
            // Contents/Frameworks, и без этого rpath dyld его не найдёт.
            // `unsafeFlags` здесь допустимы: DOKA — корневой пакет и ничьей
            // зависимостью не является.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath",
                                           "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Официальный prebuilt llama.cpp (MIT) — движок локального ИИ-анализа.
        // Пин на КОНКРЕТНЫЙ bNNNNN: релизы выходят по нескольку раз в день,
        // C-API меняется без semver. Обновление = новый url + checksum
        // (`swift package compute-checksum` = sha256 zip) + ./build.sh + smoke
        // анализа. macOS-срез ОБЯЗАН быть universal (`macos-arm64_x86_64`) —
        // build.sh это проверяет guard'ом `lipo`.
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10909/llama-b10909-xcframework.zip",
            checksum: "2a54bb807a0ebe490488f22775386db4050f3e478a111f227fca56f31207d83c"
        ),
        // Тесты чистой логики. Сплит на отдельную библиотеку НЕ нужен: SPM
        // тестирует executable-таргет напрямую, несмотря на top-level код
        // в main.swift (проверено). Покрывается только логика без UI, звука
        // и сети — остальное проверяется ручным smoke (см. CLAUDE.md).
        .testTarget(
            name: "DOKATests",
            dependencies: ["DOKA"],
            path: "Tests/DOKATests"
        )
    ]
)
