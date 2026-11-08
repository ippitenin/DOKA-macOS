import Foundation
import Network

/// Транспорт локального сервера агентов: `NWListener` только на 127.0.0.1,
/// по запросу на соединение. Порядок на каждом соединении:
/// заголовки → `preflight` (охрана и решение маршрута, главный поток) → тело
/// (в память или потоком в файл) → `handler` → ответ. Пока `preflight` не
/// разрешил, тело не читается: без токена нельзя залить даже байт.
/// Всё состояние — на своей последовательной очереди.
final class LocalAPIServer: @unchecked Sendable {
    enum State: Equatable {
        case starting
        case running(port: Int)
        case failed(String)
        case stopped
    }

    /// Куда принимать тело.
    enum BodyPlan: Sendable {
        /// В память, не больше `HTTPRequestParser.maxBodyBytes`.
        case memory
        /// Потоком в этот файл (создаётся с правами 0600).
        case file(URL)
    }

    enum Decision: Sendable {
        case reject(HTTPResponse)
        /// `onAbort` — если тело не дошло до `handler` (обрыв, простой,
        /// остановка сервера): освободить то, что занял `preflight`.
        case accept(BodyPlan, onAbort: (@Sendable () -> Void)?)
    }

    typealias Preflight = @Sendable (HTTPHead) async -> Decision
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// Заголовки должны прийти за это время простоя.
    static let headerIdleTimeout: TimeInterval = 30
    /// Тело: соединение закрывается, если байты не приходят столько секунд.
    static let bodyIdleTimeout: TimeInterval = 60
    /// Сколько ждать, пока клиент сам закроет соединение после ответа.
    static let closeGrace: TimeInterval = 5
    /// Одновременных соединений не больше: агенту хватает нескольких, а
    /// тысяча висящих соединений от чужой программы съела бы память.
    static let maxConnections = 16
    /// Порт занят сразу после выключения (TIME_WAIT прошлых соединений) —
    /// повторить один раз через столько секунд.
    static let busyRetryDelay: TimeInterval = 2

    let port: Int
    private let preflight: Preflight
    private let handler: Handler
    private let onState: @Sendable (State) -> Void
    private let queue = DispatchQueue(label: "com.pitenin.doka.agent-api")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var retriedBusyPort = false
    private var stopped = false

    init(port: Int, preflight: @escaping Preflight, handler: @escaping Handler,
         onState: @escaping @Sendable (State) -> Void) {
        self.port = port
        self.preflight = preflight
        self.handler = handler
        self.onState = onState
    }

    func start() {
        queue.async { [self] in startOnQueue() }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            stopListener()
            for connection in Array(connections.values) { close(connection) }
            onState(.stopped)
        }
    }

    private func startOnQueue() {
        guard listener == nil, !stopped else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            onState(.failed("invalid port"))
            return
        }
        let parameters = NWParameters.tcp
        // Без совместного использования адреса: иначе другая программа могла
        // бы встать на тот же 127.0.0.1:порт и перехватывать запросы вместе с
        // токеном. Цена — TIME_WAIT после выключения; поэтому соединение
        // закрывает клиент (`send`), а занятый порт повторяется.
        parameters.allowLocalEndpointReuse = false
        // Только адрес этого Mac: из сети порт не виден вовсе, и macOS не
        // спрашивает про входящие соединения.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        let created: NWListener
        do {
            created = try NWListener(using: parameters)
        } catch {
            onState(.failed(error.localizedDescription))
            return
        }
        listener = created
        onState(.starting)
        created.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onState(.running(port: self.port))
            case .failed(let error), .waiting(let error):
                self.stopListener()
                if Self.isAddressInUse(error), !self.retriedBusyPort {
                    self.retriedBusyPort = true
                    self.queue.asyncAfter(deadline: .now() + Self.busyRetryDelay) { self.startOnQueue() }
                } else {
                    self.onState(.failed(Self.describe(error)))
                }
            default:
                break
            }
        }
        created.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        created.start(queue: queue)
    }

    private func stopListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error, code == .EADDRINUSE { return true }
        return false
    }

    private static func describe(_ error: NWError) -> String {
        isAddressInUse(error) ? L("agent.server.portBusy") : error.localizedDescription
    }

    // MARK: - Соединение

    /// Состояние одного соединения; трогается только на `queue` (отсюда
    /// `@unchecked Sendable`: замыкания `Task` лишь возвращают его на очередь).
    private final class Connection: @unchecked Sendable {
        let nw: NWConnection
        var buffer = Data()
        var head: HTTPHead?
        /// Растёт с каждой порцией байт — таймер простоя сверяется с ним.
        var activity = 0
        /// Тело дошло до `handler` (или отказ отправлен): простой больше не меряем.
        var answering = false
        var closed = false
        var sink: FileHandle?
        var sinkURL: URL?
        var written = 0
        var onAbort: (@Sendable () -> Void)?

        init(_ nw: NWConnection) { self.nw = nw }
    }

    private func accept(_ nw: NWConnection) {
        nw.start(queue: queue)
        guard connections.count < Self.maxConnections else {
            nw.send(content: HTTPResponse.text("Too Many Connections", status: 503).serialized(),
                    completion: .contentProcessed { _ in nw.cancel() })
            return
        }
        let connection = Connection(nw)
        connections[ObjectIdentifier(connection)] = connection
        armIdleTimer(connection, seconds: Self.headerIdleTimeout)
        receiveHead(connection)
    }

    /// Закрыть соединение; повторный вызов ничего не делает. Недописанная
    /// загрузка — удаляется, а занятое `preflight` освобождается.
    private func close(_ connection: Connection) {
        guard !connection.closed else { return }
        connection.closed = true
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.nw.cancel()
        if let sink = connection.sink {
            try? sink.close()
            connection.sink = nil
        }
        if let abort = connection.onAbort {
            connection.onAbort = nil
            abort()
        }
    }

    private func armIdleTimer(_ connection: Connection, seconds: TimeInterval) {
        connection.activity += 1
        let mark = connection.activity
        queue.asyncAfter(deadline: .now() + seconds) { [weak self, weak connection] in
            guard let self, let connection, !connection.closed, !connection.answering,
                  connection.activity == mark else { return }
            self.close(connection)
        }
    }

    private func receiveHead(_ connection: Connection) {
        connection.nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !connection.closed else { return }
            if let data, !data.isEmpty {
                connection.buffer.append(data)
                self.armIdleTimer(connection, seconds: Self.headerIdleTimeout)
            }
            switch HTTPRequestParser.parseHead(connection.buffer) {
            case .incomplete:
                if isComplete || error != nil { self.close(connection) } else { self.receiveHead(connection) }
            case .failure(let status):
                self.respond(.text(HTTPResponse.reason(for: status), status: status), on: connection)
            case .head(let head):
                connection.head = head
                // Решение — на главном потоке; таймер простоя не тикает, пока
                // решаем (это не вина клиента).
                connection.answering = true
                let preflight = self.preflight
                Task {
                    let decision = await preflight(head)
                    self.queue.async { self.admit(connection, head: head, decision: decision) }
                }
            }
        }
    }

    private func admit(_ connection: Connection, head: HTTPHead, decision: Decision) {
        guard !connection.closed else {
            if case .accept(_, let onAbort) = decision { onAbort?() }
            return
        }
        switch decision {
        case .reject(let response):
            respond(response, on: connection)
        case .accept(.memory, let onAbort):
            connection.onAbort = onAbort
            guard head.contentLength <= HTTPRequestParser.maxBodyBytes else {
                respond(.text(HTTPResponse.reason(for: 413), status: 413), on: connection)
                return
            }
            connection.answering = false
            armIdleTimer(connection, seconds: Self.bodyIdleTimeout)
            receiveMemoryBody(connection, head: head)
        case .accept(.file(let url), let onAbort):
            connection.onAbort = onAbort
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forWritingTo: url) else {
                respond(.text(HTTPResponse.reason(for: 500), status: 500), on: connection)
                return
            }
            connection.sink = handle
            connection.sinkURL = url
            // Часть тела могла прийти вместе с заголовками.
            let already = connection.buffer.dropFirst(head.headerLength)
            connection.buffer = Data()
            connection.answering = false
            armIdleTimer(connection, seconds: Self.bodyIdleTimeout)
            writeToSink(connection, head: head, chunk: Data(already))
        }
    }

    private func receiveMemoryBody(_ connection: Connection, head: HTTPHead) {
        if connection.buffer.count - head.headerLength >= head.contentLength {
            let start = connection.buffer.startIndex + head.headerLength
            let body = Data(connection.buffer[start..<(start + head.contentLength)])
            deliver(HTTPRequest(head: head, body: body), on: connection)
            return
        }
        connection.nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !connection.closed else { return }
            if let data, !data.isEmpty {
                connection.buffer.append(data)
                self.armIdleTimer(connection, seconds: Self.bodyIdleTimeout)
            } else if isComplete || error != nil {
                self.close(connection)
                return
            }
            self.receiveMemoryBody(connection, head: head)
        }
    }

    private func writeToSink(_ connection: Connection, head: HTTPHead, chunk: Data) {
        if !chunk.isEmpty {
            // Лишние байты сверх `Content-Length` не пишем.
            let room = head.contentLength - connection.written
            let piece = chunk.prefix(room)
            do {
                try connection.sink?.write(contentsOf: piece)
            } catch {
                respond(.text(HTTPResponse.reason(for: 507), status: 507), on: connection)
                return
            }
            connection.written += piece.count
        }
        if connection.written >= head.contentLength {
            try? connection.sink?.close()
            connection.sink = nil
            let url = connection.sinkURL
            deliver(HTTPRequest(head: head, body: Data(), bodyFile: url), on: connection)
            return
        }
        connection.nw.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !connection.closed else { return }
            if let data, !data.isEmpty {
                self.armIdleTimer(connection, seconds: Self.bodyIdleTimeout)
                self.writeToSink(connection, head: head, chunk: data)
            } else if isComplete || error != nil {
                self.close(connection)
            } else {
                self.writeToSink(connection, head: head, chunk: Data())
            }
        }
    }

    /// Тело принято — дальше отвечает `handler` (он же освобождает занятое
    /// `preflight`), поэтому `onAbort` больше не нужен.
    private func deliver(_ request: HTTPRequest, on connection: Connection) {
        connection.answering = true
        connection.onAbort = nil
        let handler = self.handler
        Task {
            let response = await handler(request)
            self.queue.async { self.respond(response, on: connection) }
        }
    }

    /// Ответ с `Connection: close`, а закрывает соединение клиент: тогда
    /// TIME_WAIT остаётся у него, и порт DOKA сразу свободен для повторного
    /// включения. Клиент молчит дольше `closeGrace` — закрываем сами.
    private func respond(_ response: HTTPResponse, on connection: Connection) {
        guard !connection.closed else { return }
        connection.answering = true
        connection.nw.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
            guard let self else { connection.nw.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + Self.closeGrace) { self.close(connection) }
            connection.nw.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in
                self.close(connection)
            }
        })
    }
}
