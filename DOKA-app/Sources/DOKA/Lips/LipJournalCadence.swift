import Foundation

/// Ритм журнала лица (`capture.json`). Vision идёт на каждом кадре камеры,
/// а в журнал попадает не чаще раза в полторы номинальные длительности
/// кадра: ~15 Гц при 30 к/с, 12,5 Гц при 25 к/с — ровно как прежнее «лицо
/// на каждом втором кадре». Журнал — договор с WISLIP и вход кропа дубля:
/// его частота не должна меняться от того, что Vision стал чаще.
///
/// Порог именно 1,5 кадра, а не фиксированные 0,05 с: соседний кадр
/// отсекается, через один — проходит, и интервал между метками может
/// гулять на ±0,5 кадра при любой частоте камеры (у 0,05 с при 25 к/с
/// запас был бы 10 мс). Кадр, пропущенный занятым Vision, заменяет
/// следующий — ритм сдвигается на кадр, но не проседает.
///
/// Состояние — на `visionQueue` камеры: решение принимается там, где
/// известен результат Vision, и переходов на `videoQueue` лишь ~15 в секунду.
struct LipJournalCadence {
    /// Порог между записями журнала — в номинальных длительностях кадра.
    static let spacing = 1.5

    /// Номинальная длительность кадра камеры, с (`format.frameDuration`).
    var frameDuration: Double
    private var take: UUID?
    private var last: Double?

    init(frameDuration: Double = 1.0 / 30) {
        self.frameDuration = frameDuration
    }

    /// Пустить в журнал результат Vision по кадру `host` дубля `take`:
    /// первый результат дубля — всегда, дальше — если с прошлой записи
    /// прошло не меньше `spacing` номиналов. Новый дубль начинает ритм заново.
    mutating func admit(host: Double, take: UUID) -> Bool {
        if take != self.take {
            self.take = take
            last = nil
        }
        if let last, host - last < Self.spacing * frameDuration { return false }
        last = host
        return true
    }
}
