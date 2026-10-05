// swift-tools-version: 6.2
// 6.2, а не прежний 5.9 — ради ТРЕЙТОВ: только манифест 6.2+ может отключить
// трейт зависимости (см. FluidAudio ниже; на 6.1 синтаксис принимается, но
// бинарный таргет всё равно линкуется — проверено апстримом). Язык при этом
// остаётся Swift 5 (`swiftLanguageModes` внизу): Swift 6 включил бы строгую
// проверку конкурентности на весь код приложения. Тулчейн 6.2 = Xcode 26,
// он и так обязателен (SDK macOS 26 для Liquid Glass).
import PackageDescription

let package = Package(
    name: "DOKA",
    defaultLocalization: "en",   // язык отката для неподдерживаемых языков системы
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.1.0"),
        // Локальные модели распознавания: Whisper через WhisperKit (Argmax OSS SDK)
        // и Parakeet V3 через FluidAudio. Обе — CoreML/ANE, macOS 15+.
        // Линия 1.1.x. В 1.x два executable-продукта argmax-cli/whisperkit-cli
        // делят таргет ArgmaxCLI, и мультиарх-сборка SPM (--arch arm64 --arch
        // x86_64) падала с «duplicate key found» — поэтому DOKA долго сидела на
        // 0.18.x; с отказа от Intel сборка только arm64, и причина снята.
        // С 1.0 Hub/Tokenizers из swift-transformers встроены в ArgmaxCore —
        // отдельной зависимости на swift-transformers у WhisperKit больше нет.
        // Минорную версию поднимать отдельной правкой: release-сборка и smoke
        // Whisper Local (диктовка, файл, отмена).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", .upToNextMinor(from: "1.1.0")),
        // ТОЧНЫЙ пин, а не линия: у FluidAudio «патч» не означает патч (между
        // 0.15.5 и 0.15.7 — 237 файлов и +28 000 строк). Обновлён с 0.15.5 на
        // 0.17.5 (5.10.2026): наш код собрался без правок; живой стенд —
        // Parakeet (диктовка и файл) и офлайновый диаризатор дают на 0.17.5 те
        // же результаты, что на 0.15.5. Заодно пришли проброс отмены в
        // диаризатор, учёт лимита спикеров и «отменённая закачка не стартует».
        //
        // `traits: []` — отключён трейт NemoTextProcessing (FST-нормализация
        // текста NeMo для TTS и ITN, готовая статическая Rust-библиотека
        // text-processing-rs): DOKA ею не пользуется (текст Parakeet с ним и без
        // него одинаков), а в бинарник она добавляла 10 МБ (22,8 → 33,2 МБ;
        // без неё — 25,2). Отключить трейт может только манифест 6.2+ — см.
        // шапку файла.
        //
        // Модели диаризатора 0.17.x берёт с закреплённой ревизии: первая
        // загрузка после обновления один раз докачивает ~22 МБ (маркер
        // `.fluidaudio-revision`); 0.15.5 эти файлы тоже читает.
        //
        // Поднимать версию — только после полной проверки: `./build.sh` и
        // smoke Parakeet и диаризации.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: [])
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
        // Пин на КОНКРЕТНЫЙ bNNNNN: ежедневные сборки (теперь — пре-релизы)
        // выходят по нескольку раз в день, C-API меняется без semver. С осени
        // 2026 у ggml-org есть и стабильные релизы vX.Y.Z — это ссылка
        // (`nightly-tag.txt`) на одну из ночных сборок; пиним именно её:
        // b11146 = v0.5.0 (23.09.2026), прежний пин — b10909. Обновление = новый url + checksum
        // (`swift package compute-checksum` = sha256 zip) + ./build.sh + smoke
        // анализа. macOS-срез у ggml-org — `macos-arm64_x86_64`; build.sh
        // вырезает из него x86_64 (`lipo -thin arm64`) и проверяет результат.
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11146/llama-b11146-xcframework.zip",
            checksum: "1c306afe9fe68a90c4bdc74619d8558d6e0754f085deb105dd2d70293a9a964f"
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
    ],
    // Swift 5, а не 6: манифест 6.2 ради трейтов (см. шапку), язык прежний.
    swiftLanguageModes: [.v5]
)
