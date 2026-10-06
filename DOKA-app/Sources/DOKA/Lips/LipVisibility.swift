import CoreGraphics
import Foundation

/// Видны ли губы найденного лица: одно решение на кадр для маски и фазы
/// зеркала и для журнала дубля, а за ним — для `faceGaps` в `meta.json`.
/// Живёт на `visionQueue` камеры; состояние — на один дубль.
///
/// Губы скрыты, если:
/// - хотя бы одна точка внешнего контура губ за краем кадра — лицо найдено,
///   а рот ушёл за кромку камеры;
/// - губы закрыты ладонью. Vision на закрытом рте лицо не теряет, а
///   дорисовывает губы по форме лица — маска легла бы на ладонь, а кадры ушли
///   бы на обучение. Но этим дорисованным точкам он сам ставит высокую
///   неточность (`LipFaceSample.lipsUncertainty`). На повороте головы
///   неточность растёт у ВСЕХ точек, а на закрытом рте у губ — сильнее, чем
///   у глаз, поэтому неточность губ сравнивается ещё и с глазами.
///
/// Пороги — стенд 6.10.2026 на 42 дублях владельца из `LipData/takes`
/// (оценка Vision от масштаба не зависит: клип 512 и кадр 1280×720 дали одно
/// распределение). Открытый рот: медиана 0,0063, а там, где губы неточнее
/// глаз, — не выше 0,0112 (голова опущена, начало дубля). Ладонь на губах
/// (калибровочный дубль): не ниже 0,0137, к глазам 1,07–1,11. Вход 0,0120 —
/// посередине: ладонь поймана на всех кадрах, обычные дубли — ни на одном.
/// Палец у губ (0,0074–0,0103) закрытым не считается: губы видны почти целиком.
///
/// Лица нет — решать нечего (`box == nil` и так значит «губ не видно»); губ
/// у лица нет или нет оценок (созвездие 65) — губы считаются видимыми:
/// скрытыми их объявляет только улика.
struct LipVisibility {
    /// Губы закрываются выше этой неточности…
    static let enter = 0.0120
    /// …если она ещё и больше неточности глаз во столько раз.
    static let ratio = 1.04
    /// Закрытые губы «открываются» ниже этой неточности (гистерезис: на
    /// краю ладони она проходит порог входа, и маска мигала бы) или когда
    /// глаза стали не точнее губ — так закрытый рот переходит в поворот головы.
    static let exit = 0.0100

    private var take: UUID?
    private var covered = false

    /// Губы найденного лица скрыты. `frame` — размер кадра камеры в пикселях.
    mutating func lipsHidden(in sample: LipFaceSample, frame: CGSize, take: UUID) -> Bool {
        if take != self.take {
            self.take = take
            covered = false
        }
        guard sample.box != nil else {
            // Лицо вернётся — закрытость решается заново, с порога входа.
            covered = false
            return false
        }
        covered = Self.isCovered(lips: sample.lipsUncertainty, eyes: sample.eyesUncertainty, wasCovered: covered)
        return covered || Self.isOutside(sample.outerLips, frame: frame)
    }

    static func isCovered(lips: Double?, eyes: Double?, wasCovered: Bool) -> Bool {
        guard let lips, let eyes, eyes > 0 else { return false }
        if wasCovered { return lips >= exit && lips >= eyes }
        return lips > enter && lips / eyes > ratio
    }

    /// Хотя бы одна точка за краем кадра. Пусто — губ нет, и это не улика.
    static func isOutside(_ points: [CGPoint], frame: CGSize) -> Bool {
        points.contains { $0.x < 0 || $0.y < 0 || $0.x > frame.width || $0.y > frame.height }
    }
}
