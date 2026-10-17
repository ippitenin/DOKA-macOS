import Foundation

/// Уведомление о лицензии, зашитое в бинарник: литерал лежит открытым UTF-8
/// в `__TEXT,__cstring`, его видно через `strings` и в дизассемблере. Это
/// метка авторства для тех, кто разбирает приложение, а не защита от разбора.
/// Не удалять и не прятать за `#if DEBUG` (корневой `CLAUDE.md`).
enum LicenseNotice {
    static let text = "DOKA © 2026 Ilya Pitenin. Licensed under the GNU General Public License v3.0 (GPL-3.0). Source code: https://github.com/ippitenin/DOKA-macOS. Copies and derivative works — code, interface texts and design — may be distributed only under GPL-3.0, with complete source code and this notice preserved; closed-source distribution violates the license."
}
