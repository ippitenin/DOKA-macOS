import Foundation
import llama

// ЕДИНСТВЕННЫЙ файл с `import llama` — по образцу WhisperKit и FluidAudio:
// C-типы llama.cpp (OpaquePointer вместо моделей, llama_token, батчи) не
// должны просачиваться в остальной код. Наружу торчат только типы DOKA.

/// Сообщение чата для шаблона модели.
struct LLMMessage: Sendable, Equatable {
    enum Role: String, Sendable { case system, user, assistant }
    let role: Role
    let content: String
}

/// Что делать с генерацией: сколько токенов максимум, чем семплировать и
/// банить ли иероглифы.
struct LLMGenerationOptions: Sendable {
    var maxTokens: Int
    var sampling: LLMSampling
    /// Бан CJK-токенов. Включается, когда язык ответа не китайский, японский
    /// и не корейский: Qwen на длинном русском контексте сваливается в
    /// китайский, и это самый дешёвый способ его удержать.
    var banCJK: Bool
}

/// События генерации: сначала разбор промпта, потом текст, в конце — итог.
enum LLMEvent: Sendable {
    case prefill(Double)                 // доля обработанного промпта, 0…1
    case text(String)                    // уже валидный UTF-8 кусок ответа
    case finished(LLMGenerationResult)   // приходит ровно один раз, последним
}

struct LLMGenerationResult: Sendable {
    let text: String
    /// Генерация оборвана по лимиту токенов или детектором зацикливания —
    /// отчёт неполный, и пользователю это видно.
    let truncated: Bool
    let promptTokens: Int
    let generatedTokens: Int
    let seconds: Double
}

enum LLMError: LocalizedError {
    case modelMissing
    case loadFailed(String)
    case notLoaded
    case contextOverflow(needed: Int, available: Int)
    case templateFailed
    case decodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelMissing: return L("error.localModelMissing")
        case .loadFailed(let reason): return L("error.localLoadFailed", reason)
        case .notLoaded: return L("error.localModelMissing")
        case .contextOverflow: return L("analysis.error.contextTooSmall")
        case .templateFailed: return L("error.localLoadFailed", "chat template")
        case .decodeFailed(let code): return L("error.localLoadFailed", "llama_decode \(code)")
        }
    }
}

/// Словарь модели: непрозрачный C-тип.
private typealias LlamaVocab = OpaquePointer
/// Семплер (и цепочка семплеров): у llama.cpp это полный struct.
private typealias LlamaSampler = UnsafeMutablePointer<llama_sampler>

/// Глобальная инициализация llama.cpp: ровно один раз на процесс.
private enum LlamaBackend {
    static let ensure: Void = {
        llama_backend_init()
        // llama.cpp очень болтлив на info-уровне (каждый тензор при загрузке).
        // В лог приложения пропускаем только предупреждения и ошибки.
        llama_log_set({ level, text, _ in
            guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let text else { return }
            let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            NSLog("DOKA llama: \(message)")
        }, nil)
    }()
}

/// Локальная языковая модель поверх llama.cpp.
///
/// Свой последовательный исполнитель, а не кооперативный пул: `llama_decode`
/// — это секунды синхронной работы Metal/CPU внутри одного вызова, и в пуле
/// он занимал бы поток, на котором стоят чужие задачи. Актор при этом
/// остаётся актором: состояние (модель, контекст) защищено, вызовы
/// сериализованы.
actor LocalLLMEngine {
    private let spec: LLMModelSpec
    private let queue = DispatchSerialQueue(label: "com.doka.llm", qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    /// `llama_vocab` — непрозрачный тип, а `llama_sampler` полный, поэтому
    /// Swift отображает их по-разному; псевдонимы держат это в одном месте.
    private var vocab: LlamaVocab?
    /// Токены с иероглифами — считаются один раз при загрузке (проход по
    /// словарю на ~150k токенов), потом переиспользуются каждым запросом.
    private var cjkBans: [llama_logit_bias] = []
    private(set) var contextTokens = 0

    init(spec: LLMModelSpec = .current) {
        self.spec = spec
    }

    deinit {
        // Актор уничтожается только когда на него никто не ссылается, то есть
        // генерации уже нет: освобождать указатели безопасно.
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
    }

    var isLoaded: Bool { ctx != nil }

    // MARK: - Загрузка

    /// Загружает модель и создаёт контекст. Тяжёлая: первая загрузка под
    /// новый чип компилирует встроенные Metal-кернелы (около 12 секунд),
    /// дальше они лежат в системном кэше шейдеров.
    ///
    /// Отмены внутри нет намеренно: прерывать можно только чтение тензоров
    /// (`progress_callback`), а основное время занимает компиляция кернелов
    /// в `llama_init_from_model`, которую всё равно не прервать. Загрузка
    /// доводится до конца, а отменивший анализ просто не пойдёт дальше —
    /// зато следующий запуск стартует мгновенно.
    /// `fileURL` по умолчанию — файл из `LocalModelStore`; параметр нужен
    /// стенду, который проверяет движок на другой модели.
    func load(fileURL: URL = LocalModelStore.llmFile) throws {
        guard ctx == nil else { return }
        _ = LlamaBackend.ensure

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LLMError.modelMissing
        }

        var modelParams = llama_model_default_params()
        #if arch(arm64)
        modelParams.n_gpu_layers = -1     // все слои на Metal
        #else
        modelParams.n_gpu_layers = 0      // Intel сюда не доходит (барьер в LocalModelStore)
        #endif

        guard let loaded = llama_model_load_from_file(fileURL.path, modelParams) else {
            throw LLMError.loadFailed(fileURL.lastPathComponent)
        }

        let trained = Int(llama_model_n_ctx_train(loaded))
        let contextSize = max(1024, min(spec.contextLimit, trained > 0 ? trained : spec.contextLimit))

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextSize)
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        let threads = Int32(Self.performanceCores)
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        contextParams.no_perf = true

        guard let context = llama_init_from_model(loaded, contextParams) else {
            llama_model_free(loaded)
            throw LLMError.loadFailed("llama_init_from_model")
        }

        model = loaded
        ctx = context
        vocab = llama_model_get_vocab(loaded)
        // Фактическое окно может отличаться от запрошенного (модель вправе
        // его урезать) — берём то, что реально выделено.
        contextTokens = Int(llama_n_ctx(context))
        cjkBans = buildCJKBans()
    }

    func unload() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil
        model = nil
        vocab = nil
        cjkBans = []
        contextTokens = 0
        // llama_backend_free не зовём: бэкенд глобальный и живёт до конца
        // процесса, а повторный backend_init после него ничего не чинит.
    }

    /// Производительные ядра: на них считает и Metal-очередь, и CPU-фолбэк.
    private static var performanceCores: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    // MARK: - Токенизация

    /// Число токенов в каждой строке — одним проходом для всего входа:
    /// чанкер планирует части именно по токенам, а не по символам.
    func countTokens(_ texts: [String]) throws -> [Int] {
        guard let vocab else { throw LLMError.notLoaded }
        return texts.map { Self.tokenize($0, vocab: vocab, addSpecial: false).count }
    }

    private static func tokenize(_ text: String, vocab: LlamaVocab,
                                 addSpecial: Bool) -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        guard utf8Count > 0 else { return [] }
        // Верхняя оценка: токенов не больше, чем байт. Первый вызов с нулевым
        // буфером возвращает отрицательное нужное число — по нему и выделяем.
        var probe = Int32(0)
        text.withCString { cString in
            probe = llama_tokenize(vocab, cString, utf8Count, nil, 0, addSpecial, true)
        }
        let capacity = Int(probe < 0 ? -probe : probe)
        guard capacity > 0 else { return [] }
        var tokens = [llama_token](repeating: 0, count: capacity)
        let written = text.withCString { cString in
            tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(vocab, cString, utf8Count, buffer.baseAddress, Int32(capacity),
                               addSpecial, true)
            }
        }
        guard written > 0 else { return [] }
        return Array(tokens.prefix(Int(written)))
    }

    // MARK: - Генерация

    /// Один независимый запрос: состояние контекста сбрасывается, поэтому
    /// части map-reduce не влияют друг на друга.
    func generate(_ messages: [LLMMessage], options: LLMGenerationOptions,
                  emit: @Sendable (LLMEvent) -> Void) throws -> LLMGenerationResult {
        guard let ctx, let model, let vocab else { throw LLMError.notLoaded }
        let started = Date()

        let prompt = try applyTemplate(messages, model: model)
        var tokens = Self.tokenize(prompt, vocab: vocab, addSpecial: true)
        guard !tokens.isEmpty else { throw LLMError.templateFailed }
        guard tokens.count + options.maxTokens <= contextTokens else {
            throw LLMError.contextOverflow(needed: tokens.count + options.maxTokens,
                                           available: contextTokens)
        }

        llama_memory_clear(llama_get_memory(ctx), true)

        // ── Разбор промпта батчами: между ними проверяется отмена, поэтому
        // «Отмена» срабатывает не позже чем через один батч.
        let batchSize = 512
        var position = 0
        while position < tokens.count {
            try Task.checkCancellation()
            let count = min(batchSize, tokens.count - position)
            let status = tokens.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return llama_decode(ctx, llama_batch_get_one(base + position, Int32(count)))
            }
            guard status == 0 else { throw LLMError.decodeFailed(status) }
            position += count
            emit(.prefill(Double(position) / Double(tokens.count)))
        }

        // ── Цепочка семплеров: своя на каждый запрос, освобождается вместе
        // с чейном (он владеет добавленными семплерами).
        let chain = makeSamplerChain(options: options, vocab: vocab)
        defer { llama_sampler_free(chain) }

        var decoder = LLMText.UTF8StreamDecoder()
        var thinkFilter = LLMText.ThinkFilter()
        var loopDetector = LLMText.LoopDetector()
        var text = ""
        var generated = 0
        var truncated = false
        var pieceBuffer = [CChar](repeating: 0, count: 256)

        while generated < options.maxTokens {
            try Task.checkCancellation()
            var token = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            generated += 1

            let written = pieceBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return 0 }
                return llama_token_to_piece(vocab, token, base, Int32(buffer.count), 0, false)
            }
            if written > 0 {
                let bytes = pieceBuffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
                let decoded = decoder.append(Array(bytes))
                if !decoded.isEmpty {
                    let visible = thinkFilter.feed(decoded)
                    if !visible.isEmpty {
                        text += visible
                        emit(.text(visible))
                        if loopDetector.feed(visible) {
                            truncated = true
                            break
                        }
                    }
                }
            }

            let status = llama_decode(ctx, llama_batch_get_one(&token, 1))
            guard status == 0 else { throw LLMError.decodeFailed(status) }
        }
        if generated >= options.maxTokens { truncated = true }

        // Хвосты декодера и фильтра: последний токен мог оборваться посреди
        // символа или посреди удержанного куска тега.
        let tail = thinkFilter.feed(decoder.flush()) + thinkFilter.flush()
        if !tail.isEmpty {
            text += tail
            emit(.text(tail))
        }

        return LLMGenerationResult(text: LLMText.clean(text), truncated: truncated,
                                   promptTokens: tokens.count, generatedTokens: generated,
                                   seconds: Date().timeIntervalSince(started))
    }

    /// Потоковый вариант: события идут в стрим, отмена подписчика отменяет
    /// генерацию. Используется контроллером анализа — текст появляется по
    /// мере написания, а не разом в конце. Итог приходит событием
    /// `.finished` последним: в нём почищенный текст (`.text` отдаёт сырой,
    /// для живого показа) и признак обрыва.
    nonisolated func stream(_ messages: [LLMMessage],
                            options: LLMGenerationOptions) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await generate(messages, options: options) { event in
                        continuation.yield(event)
                    }
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Промпт

    /// Шаблон чата модели через встроенную эвристику llama.cpp (не Jinja):
    /// у Qwen это chatml, он в списке поддерживаемых. Если шаблона в GGUF
    /// нет — явный chatml, он же формат самой модели.
    private func applyTemplate(_ messages: [LLMMessage], model: OpaquePointer) throws -> String {
        let template = llama_model_chat_template(model, nil).map { String(cString: $0) } ?? "chatml"

        // C-строки живут до конца вызова: llama_chat_apply_template их только читает.
        var allocated: [UnsafeMutablePointer<CChar>] = []
        defer { allocated.forEach { free($0) } }
        func duplicate(_ string: String) -> UnsafeMutablePointer<CChar> {
            let pointer = strdup(string)!
            allocated.append(pointer)
            return pointer
        }

        let chat = messages.map {
            llama_chat_message(role: UnsafePointer(duplicate($0.role.rawValue)),
                               content: UnsafePointer(duplicate($0.content)))
        }

        // Рекомендация заголовка: вдвое больше суммарной длины сообщений.
        var capacity = max(1024, messages.reduce(0) { $0 + $1.content.utf8.count } * 2)
        for _ in 0..<2 {
            var buffer = [CChar](repeating: 0, count: capacity)
            let written = chat.withUnsafeBufferPointer { chatBuffer in
                buffer.withUnsafeMutableBufferPointer { out in
                    llama_chat_apply_template(template, chatBuffer.baseAddress, chatBuffer.count,
                                              true, out.baseAddress, Int32(out.count))
                }
            }
            guard written > 0 else { throw LLMError.templateFailed }
            if Int(written) <= capacity {
                let prompt = String(decoding: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) },
                                    as: UTF8.self)
                // Префилл пустого блока размышлений: дописывается ПОСЛЕ
                // открывающего тега ассистента, поэтому модель считает, что
                // уже подумала, и сразу пишет ответ.
                return prompt + (spec.assistantPrefill ?? "")
            }
            capacity = Int(written) + 1
        }
        throw LLMError.templateFailed
    }

    // MARK: - Семплеры

    private func makeSamplerChain(options: LLMGenerationOptions, vocab: LlamaVocab) -> LlamaSampler {
        var params = llama_sampler_chain_default_params()
        params.no_perf = true
        let chain = llama_sampler_chain_init(params)!
        let sampling = options.sampling
        let vocabSize = llama_vocab_n_tokens(vocab)

        if options.banCJK, !cjkBans.isEmpty {
            // Семплер копирует массив себе, поэтому указатель нужен только
            // на время вызова.
            cjkBans.withUnsafeBufferPointer { bans in
                llama_sampler_chain_add(chain, llama_sampler_init_logit_bias(
                    vocabSize, Int32(bans.count), bans.baseAddress))
            }
        }

        guard sampling.temperature > 0 else {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
            return chain
        }

        llama_sampler_chain_add(chain, llama_sampler_init_top_k(sampling.topK))
        // Штраф за повтор — ПОСЛЕ top_k: так советует заголовок llama.h,
        // иначе штраф размазывается по всему словарю.
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(
            vocabSize, sampling.repeatLastN, sampling.repeatPenalty, 0, 0))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(sampling.topP, 1))
        if sampling.minP > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(sampling.minP, 1))
        }
        llama_sampler_chain_add(chain, llama_sampler_init_temp(sampling.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(sampling.seed))
        return chain
    }

    /// Токены, в которых есть иероглифы, кана или хангыль. Один проход по
    /// словарю; `special: false` — служебные токены не трогаем.
    private func buildCJKBans() -> [llama_logit_bias] {
        guard let vocab else { return [] }
        var bans: [llama_logit_bias] = []
        var buffer = [CChar](repeating: 0, count: 128)
        for token in 0..<llama_vocab_n_tokens(vocab) {
            let written = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                guard let base = out.baseAddress else { return 0 }
                return llama_token_to_piece(vocab, token, base, Int32(out.count), 0, false)
            }
            guard written > 0 else { continue }
            let piece = String(decoding: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) },
                               as: UTF8.self)
            if LLMText.containsCJK(piece) {
                bans.append(llama_logit_bias(token: token, bias: -Float.infinity))
            }
        }
        return bans
    }
}
