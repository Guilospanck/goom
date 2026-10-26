import AVFoundation

// MARK: - Devices

struct CaptureDevice: Identifiable, Hashable {
    let id: String   // AVCaptureDevice.uniqueID
    let name: String

    static func cameras() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func microphones() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified
        ).devices.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
    }
}

// MARK: - Video / audio quality

enum VideoResolution: String, CaseIterable, Identifiable {
    case native = "Native", p1080 = "1080p", p720 = "720p"
    var id: String { rawValue }

    /// Longest edge, in pixels, the recording is scaled down to (never up).
    var maxLongEdge: CGFloat? {
        switch self {
        case .native: nil
        case .p1080: 1920
        case .p720: 1280
        }
    }
}

enum VideoFrameRate: Int, CaseIterable, Identifiable {
    case fps24 = 24, fps30 = 30, fps60 = 60
    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264", hevc = "HEVC"
    var id: String { rawValue }
    var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
}

enum AudioQuality: String, CaseIterable, Identifiable {
    case high = "High (48 kHz stereo)"
    case standard = "Standard (24 kHz stereo)"
    case voice = "Voice (16 kHz mono)"
    var id: String { rawValue }

    var sampleRate: Int {
        switch self {
        case .high: 48_000
        case .standard: 24_000
        case .voice: 16_000
        }
    }
    var channelCount: Int { self == .voice ? 1 : 2 }
}

enum CameraQuality: String, CaseIterable, Identifiable {
    case standard = "Standard", high = "High", hd720 = "720p", hd1080 = "1080p"
    var id: String { rawValue }

    var preset: AVCaptureSession.Preset {
        switch self {
        case .standard: .medium
        case .high: .high
        case .hd720: .hd1280x720
        case .hd1080: .hd1920x1080
        }
    }
}

// MARK: - Camera bubble

enum BubbleShape: String, CaseIterable, Identifiable {
    case circle = "Circle", rounded = "Rounded square", wide = "Wide"
    var id: String { rawValue }

    /// Height as a fraction of width.
    var aspect: CGFloat { self == .wide ? 9.0 / 16.0 : 1 }

    func cornerRadius(for size: CGSize) -> CGFloat {
        switch self {
        case .circle: min(size.width, size.height) / 2
        case .rounded, .wide: min(size.width, size.height) * 0.2
        }
    }
}

enum BubbleSize: String, CaseIterable, Identifiable {
    case small = "Small", medium = "Medium", large = "Large"
    var id: String { rawValue }

    var width: CGFloat {
        switch self {
        case .small: 140
        case .medium: 200
        case .large: 280
        }
    }
}

// MARK: - Persistence

enum Prefs {
    static func value<T: RawRepresentable>(_ key: String, default fallback: T) -> T {
        guard let raw = UserDefaults.standard.object(forKey: key) as? T.RawValue,
              let value = T(rawValue: raw) else { return fallback }
        return value
    }

    static func save<T: RawRepresentable>(_ key: String, _ value: T) {
        UserDefaults.standard.set(value.rawValue, forKey: key)
    }
}
