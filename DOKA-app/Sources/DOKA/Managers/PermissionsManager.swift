import AppKit
import AVFoundation

/// Состояние разрешений: микрофон и Универсальный доступ (Accessibility),
/// плюс камера эксперимента «Губы» — она в `allGranted` НЕ входит: диктовке
/// камера не нужна, и онбординг не должен её требовать.
@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published var micAuthorized: Bool
    /// Запрос уже был отклонён: системный промпт больше не покажется,
    /// доступ можно включить только в Системных настройках.
    @Published var micDenied: Bool
    @Published var axTrusted: Bool
    /// Камера — только для сбора пар «губы + текст». Запрашивается из раздела
    /// «Губы» по кнопке, никогда посреди диктовки.
    @Published var cameraAuthorized: Bool
    @Published var cameraDenied: Bool

    private var pollTimer: Timer?

    private init() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micAuthorized = status == .authorized
        micDenied = status == .denied || status == .restricted
        axTrusted = AXIsProcessTrusted()
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthorized = camera == .authorized
        cameraDenied = camera == .denied || camera == .restricted
    }

    var allGranted: Bool { micAuthorized && axTrusted }

    func refresh() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micAuthorized = status == .authorized
        micDenied = status == .denied || status == .restricted
        axTrusted = AXIsProcessTrusted()
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthorized = camera == .authorized
        cameraDenied = camera == .denied || camera == .restricted
    }

    func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
        return granted
    }

    /// Регистрирует приложение в списке Universal Access (тумблер появляется
    /// выключенным). Системный диалог macOS показывает максимум один раз
    /// за жизнь подписи; вызывается при показе онбординга, а не по кнопке —
    /// чтобы кнопка «Открыть настройки» не плодила два окна сразу.
    func registerAccessibility() {
        guard !axTrusted else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    func requestCamera() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        refresh()
        return granted
    }

    func openCameraSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
        NSWorkspace.shared.open(url)
    }

    /// Поллинг статусов на время онбординга.
    func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                PermissionsManager.shared.refresh()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
