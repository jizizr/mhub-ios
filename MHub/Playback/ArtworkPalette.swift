import CoreImage
import SwiftUI
import UIKit

/// Average colours of the artwork's quadrants and centre, used for the full
/// player's flowing mesh background. CoreImage's area average runs on the GPU.
enum ArtworkPalette {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    nonisolated static func colors(of image: UIImage) -> [Color] {
        guard let input = CIImage(image: image) else { return [] }
        let extent = input.extent
        let w = extent.width / 2, h = extent.height / 2
        let regions = [
            CGRect(x: extent.minX, y: extent.minY + h, width: w, height: h),
            CGRect(x: extent.minX + w, y: extent.minY + h, width: w, height: h),
            CGRect(x: extent.minX + w / 2, y: extent.minY + h / 2, width: w, height: h),
            CGRect(x: extent.minX, y: extent.minY, width: w, height: h),
            CGRect(x: extent.minX + w, y: extent.minY, width: w, height: h),
        ]
        return regions.compactMap { region in
            guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: region),
            ]), let output = filter.outputImage else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: nil)
            // Slightly darker and more saturated, like Apple Music's backgrounds.
            let color = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return Color(hue: hue, saturation: min(1, saturation * 1.15), brightness: min(0.82, brightness * 0.9))
        }
    }
}
