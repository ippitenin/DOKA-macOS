import Foundation

/// Разбор `multipart/form-data` загрузки OpenAI Audio API. Чистая логика над
/// `Data` — в приложении это отображение файла в память (`.alwaysMapped`),
/// поэтому части не копируются: у файла только диапазон байт.
///
/// Лимиты против мусора от чужой программы: заголовки части ≤ 16 КБ, текстовое
/// поле ≤ 64 КБ, частей ≤ 32, файл — ровно один.
enum MultipartFormData {
    static let maxPartHeaderBytes = 16 * 1024
    static let maxFieldBytes = 64 * 1024
    static let maxParts = 32

    struct FilePart: Equatable {
        let fieldName: String
        let fileName: String?
        let contentType: String?
        /// Байты файла в разобранном теле.
        let range: Range<Int>
    }

    struct Form: Equatable {
        /// Текстовые поля; повторы (`timestamp_granularities[]`) — по порядку.
        var fields: [String: [String]] = [:]
        var file: FilePart?

        func field(_ name: String) -> String? { fields[name]?.first }
    }

    enum ParseError: Error, Equatable {
        case badBoundary
        case malformed
        case tooManyParts
        case fieldTooLarge(String)
        case duplicateFile
    }

    /// `multipart/form-data; boundary=…` → boundary (кавычки снимаются).
    /// nil — не multipart или граница недопустима (RFC 2046: 1–70 символов).
    static func boundary(fromContentType contentType: String?) -> String? {
        guard let contentType else { return nil }
        let parts = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.first?.lowercased() == "multipart/form-data" else { return nil }
        for param in parts.dropFirst() {
            let pair = param.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "boundary" else { continue }
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard (1...70).contains(value.utf8.count), !value.contains("\r"), !value.contains("\n") else { return nil }
            return value
        }
        return nil
    }

    /// Разбор тела. `fileField` — имя поля файла (у OpenAI — `file`).
    static func parse(_ data: Data, boundary: String, fileField: String = "file") throws -> Form {
        let base = data.startIndex
        let end = data.endIndex
        let dashBoundary = Data(("--" + boundary).utf8)
        let delimiter = Data(("\r\n--" + boundary).utf8)
        let crlf = Data("\r\n".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        let closing = Data("--".utf8)

        // Преамбула до первой границы допустима (RFC 2046).
        guard let first = data.range(of: dashBoundary, in: base..<end) else { throw ParseError.badBoundary }
        var position = first.upperBound
        var form = Form()
        var count = 0
        while true {
            guard position + 2 <= end else { throw ParseError.malformed }
            if data[position..<position + 2] == closing { return form }
            // После границы допускается пробельный хвост до CRLF.
            guard let lineEnd = data.range(of: crlf, in: position..<min(end, position + 256)) else {
                throw ParseError.malformed
            }
            let partStart = lineEnd.upperBound
            count += 1
            guard count <= maxParts else { throw ParseError.tooManyParts }
            guard let headersRange = data.range(of: headerEnd,
                                                in: partStart..<min(end, partStart + maxPartHeaderBytes + 4)) else {
                throw ParseError.malformed
            }
            let headers = try parseHeaders(data[partStart..<headersRange.lowerBound])
            let contentStart = headersRange.upperBound
            guard let next = data.range(of: delimiter, in: contentStart..<end) else { throw ParseError.malformed }
            let content = contentStart..<next.lowerBound
            position = next.upperBound

            guard let disposition = headers["content-disposition"],
                  let name = parameter("name", in: disposition) else { throw ParseError.malformed }
            let fileName = parameter("filename", in: disposition)
            if name == fileField || fileName != nil {
                guard name == fileField else { continue }  // чужие файлы пропускаем
                guard form.file == nil else { throw ParseError.duplicateFile }
                form.file = FilePart(fieldName: name, fileName: fileName,
                                     contentType: headers["content-type"],
                                     range: (content.lowerBound - base)..<(content.upperBound - base))
            } else {
                guard content.count <= maxFieldBytes else { throw ParseError.fieldTooLarge(name) }
                guard let value = String(data: data[content], encoding: .utf8) else { throw ParseError.malformed }
                form.fields[name, default: []].append(value)
            }
        }
    }

    private static func parseHeaders(_ bytes: Data) throws -> [String: String] {
        guard let text = String(data: bytes, encoding: .utf8) else { throw ParseError.malformed }
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    /// Параметр заголовка: `form-data; name="file"; filename="a b.mp3"`.
    static func parameter(_ key: String, in header: String) -> String? {
        for piece in header.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0].lowercased() == key else { continue }
            var value = pair[1]
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            return value
        }
        return nil
    }
}
