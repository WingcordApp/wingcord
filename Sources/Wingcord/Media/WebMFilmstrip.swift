import Accelerate
import CoreGraphics
import CoreVideo
import Foundation

/// Turns a WebM into the same filmstrip every other moving picture in this app
/// is.
///
/// **The counterpart to `LottieFilmstrip`, and for the same reason**: a
/// container `CGImageSource` cannot open, decoded once into `AnimatedImage`'s
/// array of `CGImage`s and cached beside every GIF and APNG in
/// `AnimatedImageStore`. Everything past this file — the cache, the cost, the
/// clock, the draw — cannot tell the three apart.
///
/// Three pieces do the work, and each is a file: `WebMDemuxer` finds the coded
/// frames, `VP9Decoder` turns them into pixel buffers, and the composite below
/// puts the two streams back together and samples them to the size they will be
/// drawn at.
///
/// ## The alpha channel is a second video, and it is why this is not four lines
///
/// VP9 has no alpha. A WebM carries it as a **separate VP9 bitstream** whose
/// luma plane is the alpha channel — two decoders, two sets of reference
/// frames, decoded in lockstep and merged per frame. That is what a Discord
/// nameplate is: a 672x126 strip transparent across its leading two thirds, so
/// an asset decoded without its alpha is a black bar across somebody's name
/// rather than a slightly wrong picture.
///
/// ## Every frame is decoded and not every frame is kept
///
/// VP9 is inter-coded: frame *n* predicts from frame *n-1*, so a filmstrip that
/// only wanted a third of them would still have to decode all of them. What the
/// budget buys is how many are **composited, scaled and held** — the expensive
/// part and the resident part — while the decode runs through the loop once at
/// a bounded cost of one picture at a time.
nonisolated enum WebMFilmstrip {

    /// Whether a URL is one of these at all. Discord serves WebM for exactly one
    /// thing — an animated collectible — and nothing else in the app ends
    /// `.webm`.
    static func handles(_ url: URL) -> Bool { url.pathExtension == "webm" }

    /// The only codec this plays.
    ///
    /// VP8 and AV1 both appear in WebM and neither has ever been served here.
    /// VideoToolbox would decode AV1 and the demuxer would find its frames, but
    /// the alpha convention, the pixel format and the conversion below are all
    /// checked against VP9 and nothing else — an unchecked path that produces
    /// pictures is worse than a still, because nobody sees that it is wrong.
    private static let codecID = "V_VP9"

    /// Decodes a WebM, or returns nil when it is not one this can play.
    ///
    /// Nil for a single-frame file is the same contract `AnimatedImage.decode`
    /// keeps: the caller then uses the ordinary still path and never subscribes
    /// to the clock.
    ///
    /// - Parameter maximumPixelSize: the longest side, in pixels, the frames
    ///   are wanted at. Never upscaled — a 672-pixel strip asked for at 800
    ///   comes back at 672.
    static func decode(
        _ data: Data,
        maximumPixelSize: Int,
        byteBudget: Int = AnimatedImage.byteBudget
    ) -> AnimatedImage? {
        guard let movie = WebMDemuxer.demux(data),
              movie.track.codecID == codecID,
              movie.samples.count > 1,
              let header = VP9Header.parse(movie.samples[0].data),
              header.isPlayable,
              let picture = VP9Decoder(header: header, pixelFormat: header.pixelFormat)
        else { return nil }

        // The alpha stream carries its own header, and it is read rather than
        // assumed to match: its colour range decides which pixel format leaves
        // the plane untouched, and a rescaled alpha channel is a plate with a
        // grey haze where it should be clear.
        //
        // **A track that declares alpha and cannot produce it is refused, not
        // drawn opaque.** A nameplate is transparent across its leading two
        // thirds; the same asset with its alpha missing is a solid bar across
        // somebody's name, which is worse than the still by a long way.
        var alphaDecoder: VP9Decoder?
        if movie.track.hasAlpha {
            guard let first = movie.samples[0].alpha,
                  let alphaHeader = VP9Header.parse(first),
                  alphaHeader.isPlayable,
                  alphaHeader.width == header.width,
                  alphaHeader.height == header.height,
                  let decoder = VP9Decoder(header: alphaHeader, pixelFormat: alphaHeader.pixelFormat)
            else { return nil }
            alphaDecoder = decoder
        }

        guard var conversion = header.conversion else { return nil }

        // The drawn size, fitted to the longest side and never larger than the
        // source. A downsample cannot invent detail, and a surface that
        // over-asks would pay for it in resident pixels rather than sharpness.
        let scale = min(1, Double(maximumPixelSize) / Double(max(header.width, header.height)))
        let width = max(1, Int((Double(header.width) * scale).rounded()))
        let height = max(1, Int((Double(header.height) * scale).rounded()))
        let rowBytes = width * 4

        // How many frames the budget affords at that size, and which ones. The
        // sampler is `AnimatedImage`'s so a WebM and a GIF drop frames the same
        // way — evenly, first frame always kept, each survivor inheriting the
        // time of the ones dropped after it.
        let affordable = max(2, byteBudget / max(1, rowBytes * height))
        let keep = AnimatedImage.sampleIndices(
            count: movie.samples.count,
            budget: min(AnimatedImage.frameBudget, affordable)
        )

        var composite = Composite(width: header.width, height: header.height)
        defer { composite.release() }
        guard composite.isValid else { return nil }
        var scaler = Scaler(from: composite.buffer, width: width, height: height)
        defer { scaler.release() }

        var frames: [CGImage] = []
        var ends: [Double] = []
        var bytes = 0
        frames.reserveCapacity(keep.count)
        ends.reserveCapacity(keep.count)
        var next = 0

        for (position, sample) in movie.samples.enumerated() {
            // **Decoded whether or not it is kept.** Everything after it
            // predicts from it, so a skipped frame is every later frame ruined.
            guard let plane = picture.decode(sample.data) else { break }
            // **Both streams or neither.** A frame whose alpha is missing would
            // composite opaque — one solid flash in the middle of a loop, which
            // reads as a defect in the artwork rather than in the decode.
            var alpha: CVPixelBuffer?
            if let alphaDecoder {
                guard let coded = sample.alpha, let decoded = alphaDecoder.decode(coded)
                else { break }
                alpha = decoded
            }
            guard next < keep.count, keep[next] == position else { continue }
            next += 1

            guard composite.render(picture: plane, alpha: alpha, conversion: &conversion),
                  let image = scaler.image(from: composite.buffer, rowBytes: rowBytes)
            else { break }
            frames.append(image)
            // This frame stands in for itself and every frame dropped after it,
            // so it ends where the next KEPT frame begins.
            ends.append(
                next < keep.count ? movie.samples[keep[next]].time : movie.duration
            )
            bytes += image.height * image.bytesPerRow
        }

        guard frames.count > 1, let duration = ends.last, duration > 0 else { return nil }
        return AnimatedImage(frames: frames, ends: ends, duration: duration, cost: bytes)
    }

    // MARK: The composite

    /// One reusable full-resolution buffer, and the three passes that fill it.
    ///
    /// **Allocated once for the whole strip.** A forty-frame loop through
    /// `vImageBuffer_Init` is forty allocations of a third of a megabyte for a
    /// buffer whose contents are consumed before the next frame is decoded.
    private struct Composite {
        var buffer = vImage_Buffer()
        private(set) var isValid = false

        init(width: Int, height: Int) {
            isValid = vImageBuffer_Init(
                &buffer, vImagePixelCount(height), vImagePixelCount(width), 32,
                vImage_Flags(kvImageNoFlags)
            ) == kvImageNoError
        }

        mutating func release() {
            free(buffer.data)
            buffer.data = nil
        }

        /// Converts one picture and inserts its alpha.
        ///
        /// The result is **premultiplied BGRA**, which is what Core Graphics and
        /// Core Animation both want: an unpremultiplied image is converted on
        /// every draw and again on every `layer.contents` assignment, which for
        /// a filmstrip is once per frame forever.
        func render(
            picture: CVPixelBuffer,
            alpha: CVPixelBuffer?,
            conversion: inout vImage_YpCbCrToARGB
        ) -> Bool {
            CVPixelBufferLockBaseAddress(picture, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
            guard var luma = Self.plane(of: picture, at: 0),
                  var chroma = Self.plane(of: picture, at: 1)
            else { return false }

            // `[3, 2, 1, 0]` maps vImage's ARGB onto BGRA in memory, which with
            // `byteOrder32Little` is the one 32-bit layout Core Graphics never
            // has to swizzle.
            var destination = buffer
            let permute: [UInt8] = [3, 2, 1, 0]
            guard vImageConvert_420Yp8_CbCr8ToARGB8888(
                &luma, &chroma, &destination, &conversion, permute, 255,
                vImage_Flags(kvImageNoFlags)
            ) == kvImageNoError else { return false }

            if let alpha {
                CVPixelBufferLockBaseAddress(alpha, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(alpha, .readOnly) }
                // **The alpha stream's luma plane IS the alpha channel** — the
                // bytes are copied across, never rescaled. Verified against
                // libvpx over a whole asset: with the pixel format matched to
                // the stream's range, every sample of every frame agrees.
                guard var channel = Self.plane(of: alpha, at: 0),
                      channel.width >= destination.width,
                      channel.height >= destination.height
                else { return false }
                channel.width = destination.width
                channel.height = destination.height
                // 0x1 is the fourth byte of the pixel, which in BGRA is alpha.
                guard vImageOverwriteChannels_ARGB8888(
                    &channel, &destination, &destination, 0x1,
                    vImage_Flags(kvImageNoFlags)
                ) == kvImageNoError else { return false }
            }

            // `_RGBA8888` is the alpha-last form, which BGRA is.
            return vImagePremultiplyData_RGBA8888(
                &destination, &destination, vImage_Flags(kvImageNoFlags)
            ) == kvImageNoError
        }

        /// One plane of a locked pixel buffer, as vImage sees it.
        ///
        /// The buffer is bi-planar — luma, then interleaved chroma — so the
        /// second plane is half the width and half the height with two bytes per
        /// sample, which is exactly what `vImageConvert_420Yp8_CbCr8ToARGB8888`
        /// expects.
        private static func plane(of buffer: CVPixelBuffer, at index: Int) -> vImage_Buffer? {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, index) else { return nil }
            return vImage_Buffer(
                data: base,
                height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(buffer, index)),
                width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(buffer, index)),
                rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, index)
            )
        }
    }

    /// The downsample, and the `CGImage` that comes out of it.
    ///
    /// **Its scratch space is allocated once**, from vImage's own answer to how
    /// much it needs — the alternative is an allocation and a free inside every
    /// frame of the loop.
    ///
    /// **Scaled after the alpha is in and premultiplied, never before.**
    /// Resampling unpremultiplied colour pulls whatever happens to be under a
    /// transparent pixel into its neighbours, which on a strip that is
    /// transparent across two thirds of its width is a dark halo down the
    /// leading edge of the artwork.
    private struct Scaler {
        private let width: Int
        private let height: Int
        private let isIdentity: Bool
        private var temporary: UnsafeMutableRawPointer?

        init(from source: vImage_Buffer, width: Int, height: Int) {
            self.width = width
            self.height = height
            isIdentity = source.width == vImagePixelCount(width)
                && source.height == vImagePixelCount(height)
            guard !isIdentity else { return }
            var input = source
            var probe = vImage_Buffer(
                data: nil,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width * 4
            )
            let size = vImageScale_ARGB8888(
                &input, &probe, nil,
                vImage_Flags(kvImageGetTempBufferSize | kvImageHighQualityResampling)
            )
            if size > 0 { temporary = malloc(size) }
        }

        mutating func release() {
            free(temporary)
            temporary = nil
        }

        /// Scales into a fresh buffer and hands it to a `CGImage`, which owns it
        /// from that moment.
        ///
        /// **The bytes are given away rather than copied.** A `CGDataProvider`
        /// built over the allocation frees it when the image is released, which
        /// is what makes a filmstrip cost exactly its pixels — going through
        /// `CGContext.makeImage()` would copy every frame a second time.
        func image(from source: vImage_Buffer, rowBytes: Int) -> CGImage? {
            let count = rowBytes * height
            guard let bytes = malloc(count) else { return nil }
            var destination = vImage_Buffer(
                data: bytes,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: rowBytes
            )
            var input = source
            let status: vImage_Error
            if isIdentity {
                status = vImageCopyBuffer(
                    &input, &destination, 4, vImage_Flags(kvImageNoFlags)
                )
            } else {
                status = vImageScale_ARGB8888(
                    &input, &destination, temporary,
                    vImage_Flags(kvImageHighQualityResampling)
                )
            }
            guard status == kvImageNoError,
                  let provider = CGDataProvider(
                      dataInfo: bytes,
                      data: bytes,
                      size: count,
                      releaseData: { info, _, _ in free(info) }
                  )
            else {
                free(bytes)
                return nil
            }
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: rowBytes,
                space: Self.colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        }

        /// **sRGB, named rather than device.** These frames land beside a still
        /// PNG of the same artwork on the same row, and an untagged bitmap is
        /// colour-managed differently from a tagged one — which shows as the
        /// plate shifting hue the moment it starts moving.
        private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
    }
}

nonisolated extension VP9Header {
    /// The pixel format that leaves this stream's planes alone.
    ///
    /// Matching the stream's own range is what makes VideoToolbox hand the
    /// decoded samples over rather than rescaling them on the way out. It is a
    /// nicety for the picture and it is **load-bearing for the alpha**, which is
    /// carried as a luma plane and means nothing after a range conversion.
    var pixelFormat: OSType {
        isFullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    /// The YCbCr-to-RGB conversion this stream asks for.
    ///
    /// **Unspecified means BT.601 here, which is a choice and not a reading.**
    /// Every nameplate Discord serves carries colour space 0 — "unknown" — and
    /// VP9 gives a decoder nothing else to go on. 601 is what libvpx's own
    /// consumers settle on for an unflagged stream of this size, and it is what
    /// this app's frames were checked against; taking 709 instead would leave
    /// the still and the animation visibly different reds on the same row.
    var conversion: vImage_YpCbCrToARGB? {
        var range =
            isFullRange
            ? vImage_YpCbCrPixelRange(
                Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255,
                YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
            : vImage_YpCbCrPixelRange(
                Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
        // VP9 colour space 2 is BT.709; 5 is BT.2020, whose luma weights are
        // close enough to 709's that its matrix is the right stand-in for one
        // this has no constant for.
        var matrix = colorSpace == 2 || colorSpace == 5 ? Self.bt709 : Self.bt601
        var info = vImage_YpCbCrToARGB()
        guard vImageConvert_YpCbCrToARGB_GenerateConversion(
            &matrix, &range, &info, kvImage420Yp8_CbCr8, kvImageARGB8888,
            vImage_Flags(kvImageNoFlags)
        ) == kvImageNoError else { return nil }
        return info
    }

    // The two ITU matrices, written out rather than taken from vImage's own
    // `kvImage_YpCbCrToARGBMatrix_ITU_R_*` globals.
    //
    // **Not a preference — those globals cannot be read from here.** The SDK
    // declares each as a *mutable pointer* to a constant matrix, so Swift
    // imports it as a global `var` and Swift 6 refuses the read as shared
    // mutable state. There is no annotation that makes it legal.
    //
    // Both are the recommendations themselves, and each field follows from the
    // luma coefficients in one line: `Cr_R = 2(1-Kr)`, `Cb_B = 2(1-Kb)`,
    // `Cr_G = -2·Kr(1-Kr)/Kg`, `Cb_G = -2·Kb(1-Kb)/Kg`. `Yp` is 1 because the
    // studio-range scaling lives in the pixel range beside it, not in here.
    // `WebMFilmstripTests` pins them against a decode of a real asset.

    /// Kr 0.299, Kb 0.114 — ITU-R BT.601-4.
    private static var bt601: vImage_YpCbCrToARGBMatrix {
        vImage_YpCbCrToARGBMatrix(
            Yp: 1, Cr_R: 1.402, Cr_G: -0.714136, Cb_G: -0.344136, Cb_B: 1.772
        )
    }

    /// Kr 0.2126, Kb 0.0722 — ITU-R BT.709-2.
    private static var bt709: vImage_YpCbCrToARGBMatrix {
        vImage_YpCbCrToARGBMatrix(
            Yp: 1, Cr_R: 1.5748, Cr_G: -0.468124, Cb_G: -0.187324, Cb_B: 1.8556
        )
    }
}
