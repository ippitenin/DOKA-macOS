import CoreAudio
import Foundation

/// Буст громкости системного микрофона на время записи: на старте — максимум,
/// после — прежнее значение. Best-effort через CoreAudio HAL: работает только
/// с устройством ввода по умолчанию и только если оно позволяет менять
/// громкость программно (многие USB и агрегатные устройства — нет; тогда
/// молча ничего не делаем).
@MainActor
final class MicrophoneVolumeBooster {
    /// Что бустили: устройство и его громкость до буста.
    private var saved: (device: AudioDeviceID, volume: Float32)?

    /// Выставить громкость входа на максимум, запомнив текущую.
    func beginBoost() {
        guard saved == nil else { return }   // повторный старт без end — не наслаиваем
        guard let device = Self.defaultInputDevice(),
              let address = Self.volumeAddress(for: device),
              let volume = Self.readVolume(device: device, address: address),
              volume < 0.999 else { return } // уже на максимуме — нечего возвращать
        guard Self.writeVolume(1.0, device: device, address: address) else { return }
        saved = (device, volume)
    }

    /// Вернуть прежнюю громкость. Идемпотентно: без beginBoost — no-op.
    func endBoost() {
        guard let saved else { return }
        self.saved = nil
        guard let address = Self.volumeAddress(for: saved.device) else { return }
        _ = Self.writeVolume(saved.volume, device: saved.device, address: address)
    }

    /// Текущая системная громкость входа устройства по умолчанию (0…1); nil —
    /// у устройства нет управляемой громкости. Для подсказки «микрофон тихий».
    static func currentInputVolume() -> Float? {
        guard let device = defaultInputDevice(),
              let address = volumeAddress(for: device) else { return nil }
        return readVolume(device: device, address: address)
    }

    // MARK: - CoreAudio HAL

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return (status == noErr && device != kAudioObjectUnknown) ? device : nil
    }

    /// Адрес записываемой громкости входа: main-элемент, фолбэк — канал 1.
    private static func volumeAddress(for device: AudioDeviceID) -> AudioObjectPropertyAddress? {
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            var settable = DarwinBoolean(false)
            if AudioObjectHasProperty(device, &address),
               AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
               settable.boolValue {
                return address
            }
        }
        return nil
    }

    private static func readVolume(device: AudioDeviceID,
                                   address: AudioObjectPropertyAddress) -> Float32? {
        var address = address
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    private static func writeVolume(_ volume: Float32, device: AudioDeviceID,
                                    address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var volume = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &volume) == noErr
    }
}
