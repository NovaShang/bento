import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BentoCore

/// Regression net for the pasted-image bug: the macOS pasteboard often only
/// carries TIFF, and the composer used to forward it verbatim as `image/tiff`
/// — a format the ACP agent (and the Claude API behind it) can't read, so the
/// image was silently dropped ("dimensions could not be read from the file
/// header"). `process` must land every attachment on an agent-safe format.
@Suite struct ImageAttachmentProcessorTests {
    private func makeImage(_ width: Int, _ height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func encode(_ image: CGImage, as type: UTType) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func maxDimension(_ data: Data) -> Int {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return 0 }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return max(w, h)
    }

    /// The core invariant: whatever comes in, the output MIME is one the agent
    /// accepts (never image/tiff, image/heic, …).
    @Test func alwaysProducesAgentSafeMIME() {
        let small = makeImage(400, 300)
        for type in [UTType.tiff, .png, .gif, .bmp] {
            let processed = ImageAttachmentProcessor.process(encode(small, as: type))
            let mime = try! #require(processed?.mimeType, "\(type.identifier) was dropped")
            #expect(
                ImageAttachmentProcessor.agentSafeMIMETypes.contains(mime),
                "\(type.identifier) produced unsafe MIME \(mime)")
        }
    }

    /// The bug's exact repro: a small pasteboard TIFF must be re-encoded, not
    /// shipped as image/tiff.
    @Test func smallTIFFisReencoded() {
        let tiff = encode(makeImage(400, 300), as: .tiff)
        let processed = try! #require(ImageAttachmentProcessor.process(tiff))
        #expect(processed.mimeType != "image/tiff")
        #expect(processed.mimeType == "image/jpeg")
    }

    /// Already-safe small images stay byte-identical — no pointless re-encode.
    @Test func smallSafeImagesPassThrough() {
        let png = encode(makeImage(400, 300), as: .png)
        let processed = try! #require(ImageAttachmentProcessor.process(png))
        #expect(processed.mimeType == "image/png")
        #expect(processed.data == png)
    }

    /// Oversized images are downscaled under the pixel cap (and JPEG-encoded).
    @Test func oversizedImagesAreDownscaled() {
        let big = encode(makeImage(3000, 2000), as: .png)
        let processed = try! #require(ImageAttachmentProcessor.process(big))
        #expect(processed.mimeType == "image/jpeg")
        #expect(maxDimension(processed.data) <= ImageAttachmentProcessor.maxPixelSize)
    }

    /// Undecodable bytes are rejected (surfaces as a composer notice upstream).
    @Test func garbageIsRejected() {
        #expect(ImageAttachmentProcessor.process(Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }
}
