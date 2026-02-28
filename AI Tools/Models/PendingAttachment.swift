import Foundation
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct PendingAttachment: Identifiable {
    let id = UUID()
    let name: String
    let mimeType: String
    let base64Data: String
    let previewJPEGData: Data?

    static func fromFileURL(_ url: URL) throws -> PendingAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        if data.count > 18_000_000 {
            throw GeminiError.api("File '\(url.lastPathComponent)' is too large (limit 18MB).")
        }

        let originalMimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let processed = try preprocessIfImage(data: data, mimeType: originalMimeType)

        return PendingAttachment(
            name: processed.fileNameOverride ?? url.lastPathComponent,
            mimeType: processed.mimeType,
            base64Data: processed.data.base64EncodedString(),
            previewJPEGData: makePreviewData(data: processed.data, mimeType: processed.mimeType)
        )
    }

    private static func preprocessIfImage(data: Data, mimeType: String) throws -> (data: Data, mimeType: String, fileNameOverride: String?) {
        guard mimeType.hasPrefix("image/") else {
            return (data, mimeType, nil)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return (data, mimeType, nil)
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return (data, mimeType, nil)
        }

        let side = min(width, height)
        let x = (width - side) / 2
        let y = (height - side) / 2
        let cropRect = CGRect(x: x, y: y, width: side, height: side)
        guard let cropped = image.cropping(to: cropRect) else {
            return (data, mimeType, nil)
        }

        let maxSide = 1280
        let targetSide = min(side, maxSide)
        guard let context = CGContext(
            data: nil,
            width: targetSide,
            height: targetSide,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (data, mimeType, nil)
        }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: targetSide, height: targetSide))
        guard let outputImage = context.makeImage() else {
            return (data, mimeType, nil)
        }

        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return (data, mimeType, nil)
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.72
        ]
        CGImageDestinationAddImage(destination, outputImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return (data, mimeType, nil)
        }

        return (outputData as Data, "image/jpeg", nil)
    }

    private static func makePreviewData(data: Data, mimeType: String) -> Data? {
        guard mimeType.hasPrefix("image/"),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 220,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumb, [
            kCGImageDestinationLossyCompressionQuality: 0.65
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return out as Data
    }

#if os(macOS)
    var previewImage: NSImage? {
        guard let previewJPEGData else { return nil }
        return NSImage(data: previewJPEGData)
    }
#elseif os(iOS)
    var previewImage: UIImage? {
        guard let previewJPEGData else { return nil }
        return UIImage(data: previewJPEGData)
    }
#endif
}
