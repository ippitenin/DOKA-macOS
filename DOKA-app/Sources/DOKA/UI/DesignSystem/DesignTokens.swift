import SwiftUI

/// Дизайн-токены DOKA: единственный источник правды для радиусов,
/// отступов, анимаций и палитр редизайна Liquid Glass.
enum DS {
    /// Фирменный акцент: персиковый, в тон свечениям фона.
    /// Используется для выделения и главных кнопок.
    static let accent = Color(red: 0.99, green: 0.57, blue: 0.40)

    /// Цвет свечений фона: яркий насыщенный персиковый.
    static let glow = Color(red: 1.0, green: 0.60, blue: 0.42)

    /// Глубокий коралл — тёплый вторичный акцент (превью-волны, аврора-превью).
    static let coral = Color(red: 1.0, green: 0.46, blue: 0.33)

    /// Радиусы скруглений. Контролы (кнопки, поля, выделение) — капсулы;
    /// контейнеры — концентрично радиусу окна Tahoe (~26 − инсет 10 = 16).
    enum Radius {
        static let card: CGFloat = 16
        static let sidebar: CGFloat = 16
        static let badge: CGFloat = 12
    }

    /// Отступы и габариты.
    enum Spacing {
        /// Отступ «парящей» плашки сайдбара от краёв окна.
        static let windowInset: CGFloat = 10
        /// Горизонтальные поля контента секций.
        static let section: CGFloat = 24
        static let cardPadding: CGFloat = 14
    }

    /// Ширина плашки сайдбара.
    enum Sidebar {
        static let expanded: CGFloat = 215
    }

    /// Анимации. Spring-пресеты .smooth/.snappy доступны с macOS 14.
    enum Anim {
        static let section: Animation = .smooth(duration: 0.25)
        static let hover: Animation = .snappy(duration: 0.15)
        /// Отклик контролов: копирование, появление панели мультивыбора и т.п.
        static let control: Animation = .snappy(duration: 0.2)
        /// Появление/скрытие панели рекордера (NSAnimationContext).
        static let panelShow: TimeInterval = 0.22
        static let panelHide: TimeInterval = 0.18
    }

    /// Палитра mesh-фона: 9 цветов сетки 3×3, слева направо и сверху вниз.
    /// Тёмная тема — глубокий сине-фиолетовый тинт (Huly-стиль, накладывается
    /// с малой непрозрачностью), светлая — почти белая с холодными переливами.
    static func meshColors(for scheme: ColorScheme) -> [Color] {
        switch scheme {
        case .dark:
            return [
                Color(red: 0.04, green: 0.06, blue: 0.18),
                Color(red: 0.08, green: 0.08, blue: 0.28),
                Color(red: 0.04, green: 0.08, blue: 0.24),
                Color(red: 0.07, green: 0.07, blue: 0.26),
                Color(red: 0.12, green: 0.11, blue: 0.36),
                Color(red: 0.06, green: 0.10, blue: 0.30),
                Color(red: 0.03, green: 0.09, blue: 0.24),
                Color(red: 0.09, green: 0.08, blue: 0.30),
                Color(red: 0.05, green: 0.11, blue: 0.28)
            ]
        default:
            return [
                Color(red: 0.93, green: 0.95, blue: 0.99),
                Color(red: 0.90, green: 0.92, blue: 0.99),
                Color(red: 0.94, green: 0.96, blue: 1.00),
                Color(red: 0.91, green: 0.94, blue: 0.99),
                Color(red: 0.87, green: 0.90, blue: 0.98),
                Color(red: 0.92, green: 0.95, blue: 1.00),
                Color(red: 0.94, green: 0.97, blue: 1.00),
                Color(red: 0.90, green: 0.93, blue: 0.99),
                Color(red: 0.93, green: 0.96, blue: 1.00)
            ]
        }
    }

    /// Палитра фирменной лого-марки (`DokaLogoMark`): тёплый персиковый
    /// в тон цветному логотипу-иконке — светлая вершина к насыщенному
    /// основанию.
    enum Logo {
        static let markLight = Color(red: 0.98, green: 0.78, blue: 0.66)
        static let markDeep = Color(red: 0.99, green: 0.55, blue: 0.38)
    }

    /// Палитра стиля «Аврора»: глубокий индиго и космическая подложка пилюли
    /// (в дополнение к фирменному персику `accent`/`glow`).
    enum Aurora {
        static let indigo = Color(red: 0.55, green: 0.56, blue: 0.99)
        /// Пересвеченное ядро волны: тёплый почти-белый (шейдер `dokaDropWave`).
        static let waveHighlight = Color(red: 1.0, green: 0.93, blue: 0.88)
        /// Сердцевина капель распознавания: холодный лавандовый
        /// (шейдер `dokaDropDots`).
        static let dotHighlight = Color(red: 0.72, green: 0.79, blue: 1.0)
        /// Градиент-подложка пилюли (сверху-слева → снизу-справа).
        static let cosmic: [Color] = [
            Color(red: 0.07, green: 0.06, blue: 0.18),
            Color(red: 0.13, green: 0.09, blue: 0.25),
            Color(red: 0.10, green: 0.07, blue: 0.20)
        ]
        /// Палитра «Мини» — ХОЛОДНАЯ целиком, без единого тёплого оттенка
        /// (решение пользователя: тёплое рядом с бирюзой всегда спорило).
        /// Яркая ведущая нить осталась светлой, но ушла в лёд; две другие —
        /// насыщенные бирюза Тиффани и сине-фиолетовый. Тёплые токены
        /// (`DS.accent`/`DS.glow`) в этой палитре не использовать.
        static let miniIce = Color(red: 0.72, green: 0.94, blue: 1.00)
        static let miniTiffany = Color(red: 0.04, green: 0.84, blue: 0.80)
        static let miniViolet = Color(red: 0.42, green: 0.36, blue: 1.00)
        /// Пересвеченное ядро волны «Мини»: холодный почти-белый (у «Авроры»
        /// на этом месте тёплый `waveHighlight`).
        static let miniHighlight = Color(red: 0.90, green: 0.98, blue: 1.00)
        /// Подложка «Мини» (`DropLook.mini`): тёмный синий с уходом в фиолет —
        /// на нём бирюза читается переливом, а не вторым акцентом.
        static let cosmicDeep: [Color] = [
            Color(red: 0.020, green: 0.045, blue: 0.140),
            Color(red: 0.050, green: 0.055, blue: 0.220),
            Color(red: 0.030, green: 0.048, blue: 0.170)
        ]
    }

    /// Зеркало губ (эксперимент «Губы»): холодная sci-fi-гамма контура на
    /// чёрной плашке — в родстве с палитрой «Мини», без тёплых акцентов.
    enum Lips {
        /// Контур губ — ледяной голубой.
        static let contour = Color(red: 0.55, green: 0.94, blue: 1.00)
        /// Ключевые точки контура — бирюза.
        static let dot = Color(red: 0.04, green: 0.84, blue: 0.80)
        /// Тонкая кромка кадра видео.
        static let rim = Color.white.opacity(0.14)
        /// Подписи состояний поверх кадра.
        static let caption = Color.white.opacity(0.78)
    }

    /// Тёплая палитра полноэкранной подсветки краёв («Аврора», `ScreenGlowView`):
    /// персик → янтарь → коралл.
    enum ScreenGlow {
        static let peach = Color(red: 1.00, green: 0.58, blue: 0.38)
        static let amber = Color(red: 1.00, green: 0.70, blue: 0.44)
        static let coral = Color(red: 1.00, green: 0.42, blue: 0.34)
    }

    /// Брендовые тоны состояний рекордера: запись — тёплый персик,
    /// распознавание — прохладный индиго (в тон космической палитре),
    /// ошибка остаётся тревожной (янтарь). Единый источник для тинтов
    /// стекла, волны и точки записи.
    enum RecorderTone {
        static let recording = DS.accent                              // персик
        static let transcribing = Color(red: 0.55, green: 0.62, blue: 0.99)  // индиго
        static let error = Color(red: 1.0, green: 0.78, blue: 0.30)   // янтарь
    }

    /// Стекло панели остаётся НЕЙТРАЛЬНЫМ во всех состояниях. Статус читается
    /// по цвету волны/точки (персик — запись, индиго — распознавание) и по
    /// содержимому, а не заливкой всей плашки — иначе персиковая волна
    /// сливается с персиковым стеклом в сплошное пятно.
    static func recorderTint(for _: DictationController.State) -> Color? {
        nil
    }
}
