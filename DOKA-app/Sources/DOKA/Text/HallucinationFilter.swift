import Foundation

/// Дежурные фразы, которые Whisper выдаёт на почти тишине: он учился на
/// субтитрах YouTube, где тишина в конце ролика — «Спасибо за просмотр».
/// Замер: 1 с тишины даёт «Продолжение следует...» (language=ru) или «You»
/// (автоопределение), причём сам Whisper ставит `no_speech_prob` 0.0 — по его
/// оценке такой мусор не отсеять. От тишины защищает гейт, но в тихом режиме
/// его порог низкий, и короткая пустая запись с шорохом проходила и вставляла
/// «Thank you.». Чистая функция — покрыта тестами.
///
/// Отсекается только результат ЦЕЛИКОМ (или повтор одной такой фразы):
/// внутри настоящей диктовки эти слова — обычный текст.
enum HallucinationFilter {
    /// Никогда не диктуются сами по себе — отсекаем в любом режиме.
    private static let subtitleArtifacts: [[String]] = [
        "продолжение следует",
        "субтитры сделал dimatorzok",
        "субтитры создавал dimatorzok",
        "субтитры делал dimatorzok",
        "редактор субтитров а синецкая корректор а егорова",
        "спасибо за просмотр",
        "подписывайтесь на канал",
        "thanks for watching",
        "thank you for watching",
    ].map(words)

    /// Днём «Спасибо» вслух — нормальная короткая диктовка (ответ в чате), её
    /// не трогаем. В тихом режиме шёпот от шороха по громкости не отличить
    /// (у настоящих шёпотных фраз 0,2–0,3 с над порогом, у шороха — столько же),
    /// поэтому там такая фраза целиком — почти наверняка тишина.
    private static let quietOnlyArtifacts: [[String]] = [
        "спасибо",
        "спасибо за внимание",
        "thank you",
        "thanks",
        "you",
        "bye",
    ].map(words)

    static func isHallucination(_ text: String, quiet: Bool) -> Bool {
        let tokens = words(text)
        guard !tokens.isEmpty else { return false }
        let candidates = quiet ? subtitleArtifacts + quietOnlyArtifacts : subtitleArtifacts
        return candidates.contains { isRepetition(tokens, of: $0) }
    }

    /// Слова без регистра, ё = е, без пунктуации: «А.Синецкая» → «а синецкая».
    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// `tokens` — это `phrase`, повторённая один или несколько раз.
    private static func isRepetition(_ tokens: [String], of phrase: [String]) -> Bool {
        guard !phrase.isEmpty, tokens.count % phrase.count == 0 else { return false }
        return stride(from: 0, to: tokens.count, by: phrase.count).allSatisfy {
            Array(tokens[$0..<$0 + phrase.count]) == phrase
        }
    }
}
