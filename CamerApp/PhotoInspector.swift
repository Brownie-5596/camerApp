import ImageIO
import SwiftUI

/// Reads a photo's metadata and describes it in plain text, so it can be checked or pasted into a chat
/// (sharing an image directly usually strips this information).
enum PhotoInspector {
    static func report(for data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return "Couldn't read this photo."
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]

        let software = tiff[kCGImagePropertyTIFFSoftware as String] as? String ?? ""
        let comment = exif[kCGImagePropertyExifUserComment as String] as? String ?? ""
        let fromApp = software.contains("CamerApp") || comment.contains("CamerApp")

        var lines: [String] = []
        if fromApp {
            lines.append("Taken with: \(software.contains("CamerApp") ? software : "CamerApp")")
        } else {
            lines.append("Taken with: \(software.isEmpty ? "unknown app" : software) (no CamerApp settings found)")
        }

        let make = tiff[kCGImagePropertyTIFFMake as String] as? String ?? ""
        let model = tiff[kCGImagePropertyTIFFModel as String] as? String ?? ""
        if !model.isEmpty { lines.append("Camera: \(make) \(model)".replacingOccurrences(of: "Apple Apple", with: "Apple")) }
        if let lens = exif[kCGImagePropertyExifLensModel as String] as? String { lines.append("Lens: \(lens)") }

        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        lines.append("File: \(fileType(source)), \(width)×\(height) (\(width * height / 1_000_000) MP), \(byteCount(data.count))")

        if let exposure = exif[kCGImagePropertyExifExposureTime as String] as? Double {
            lines.append("Shutter: \(Stops.shutterLabel(exposure))")
        }
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], let iso = isos.first {
            lines.append("ISO: \(iso)")
        }
        if let f = exif[kCGImagePropertyExifFNumber as String] as? Double {
            lines.append(String(format: "Aperture: f/%.2f", f))
        }
        if let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double {
            var text = String(format: "Focal length: %.2f mm", focal)
            if let focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int { text += " (\(focal35) mm equivalent)" }
            lines.append(text)
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue as String] as? Double {
            lines.append("Exposure compensation: \(Stops.evLabel(Float(bias)))")
        }
        if let program = exif[kCGImagePropertyExifExposureProgram as String] as? Int {
            let names = [1: "manual", 2: "program (auto)", 3: "aperture priority", 4: "shutter priority"]
            lines.append("Exposure mode: \(names[program] ?? "\(program)")")
        }
        if let wb = exif[kCGImagePropertyExifWhiteBalance as String] as? Int {
            lines.append("White balance: \(wb == 1 ? "manual" : "auto")")
        }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String ?? ""
            lines.append("Taken: \(date) \(offset)")
        }
        if let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? ""
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? ""
            var text = String(format: "Location: %.4f° %@, %.4f° %@", lat, latRef, lon, lonRef)
            if let altitude = gps[kCGImagePropertyGPSAltitude as String] as? Double { text += String(format: ", %.0f m", altitude) }
            if let direction = gps[kCGImagePropertyGPSImgDirection as String] as? Double { text += String(format: ", facing %.0f°", direction) }
            lines.append(text)
        } else {
            lines.append("Location: none")
        }
        if !comment.isEmpty { lines.append("Details: \(comment)") }
        if let description = tiff[kCGImagePropertyTIFFImageDescription as String] as? String,
           !description.isEmpty, !comment.contains(description) {
            lines.append("Description: \(description)")
        }
        return lines.joined(separator: "\n")
    }

    private static func fileType(_ source: CGImageSource) -> String {
        switch CGImageSourceGetType(source) as String? {
        case "public.heic", "public.heif": return "HEIF"
        case "com.adobe.raw-image": return "DNG (RAW / ProRAW)"
        case "public.jpeg": return "JPEG"
        case "public.tiff": return "TIFF"
        case "public.png": return "PNG"
        case let other?: return other
        case nil: return "unknown"
        }
    }

    private static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Shows a photo's report with a button to copy it.
struct PhotoReportView: View {
    let report: String
    let theme: Theme
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .foregroundStyle(theme.primary)
            .background(Color.black)
            .navigationTitle("Photo settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = report
                        copied = true
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
