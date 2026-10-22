import Foundation
import WingcordCore

// MARK: - Sending a file
//
// **The cloud flow, for every upload, without a multipart path beside it.**
// Discord takes attachments two ways: `multipart/form-data` straight to the
// message route, and a three-step handshake that puts the bytes into Google
// Cloud Storage and then names them in the message. This client only implements
// the second, and that is a decision rather than an omission:
//
//  - Above 200 MiB the multipart form does not work at all — Discord's edge
//    refuses the request body — so a client that wants a Nitro account's 500 MiB
//    needs this path regardless, and having *both* means the large case is the
//    one nobody exercises.
//  - Multipart holds every byte of the message in memory to build the form. A
//    half-gigabyte video would be assembled in RAM twice over. `URLSession`'s
//    upload task streams from the file instead and peaks at a buffer.
//  - The pre-signed URL is not Discord's host, so it must not carry Discord's
//    authorization header. One path means one place that rule is written down.
//
// The handshake, in order:
//
//  1. `POST /channels/{id}/attachments` with each file's name and size. Discord
//     answers with a pre-signed `upload_url` and the `upload_filename` that
//     names the object once it is there.
//  2. `PUT` the bytes at `upload_url`. No token, no client headers.
//  3. `POST /channels/{id}/messages` with `attachments: [{id, filename,
//     uploaded_filename}]`. The `id` is the placeholder index from step one, and
//     it is what ties the slot to the entry — Discord matches on it, not on the
//     file name.

/// One file, on its way up.
public struct UploadSlot: Sendable {
    /// The placeholder index the message body has to echo back. A string on the
    /// wire, an ordinal in practice — `"0"`, `"1"`, `"2"`.
    public var id: String
    /// Where the bytes go. Pre-signed and short-lived.
    public var uploadURL: URL
    /// What the message names the object as. **Not the file's own name** — it is
    /// a UUID-prefixed path Discord mints, and sending the reader's file name
    /// here is how an upload lands as a 500 from the message route.
    public var uploadedFilename: String
    /// The name the message will *show*. Carried alongside because the reader
    /// named the file and `uploadedFilename` did not.
    public var filename: String

    public init(id: String, uploadURL: URL, uploadedFilename: String, filename: String) {
        self.id = id
        self.uploadURL = uploadURL
        self.uploadedFilename = uploadedFilename
        self.filename = filename
    }
}

/// A file the caller wants a slot for.
public struct UploadRequest: Sendable {
    public var filename: String
    public var size: Int
    /// A description for screen readers, carried through to the attachment.
    public var altText: String?
    /// Whether the file is hidden behind a spoiler. Discord carries no flag for
    /// it: the *name* is the flag, and it is prefixed on the way out.
    public var isSpoiler: Bool
    /// What makes it a Discord clip rather than a video — see `ClipUpload`.
    public var clip: ClipUpload?

    public init(
        filename: String,
        size: Int,
        altText: String? = nil,
        isSpoiler: Bool = false,
        clip: ClipUpload? = nil
    ) {
        self.filename = filename
        self.size = size
        self.altText = altText
        self.isSpoiler = isSpoiler
        self.clip = clip
    }

    /// The name Discord is asked to reserve. `SPOILER_` is how every client
    /// marks one, and Discord's own `Attachment.isSpoiler` reads it back off
    /// the name.
    public var wireFilename: String {
        isSpoiler && !filename.hasPrefix("SPOILER_") ? "SPOILER_\(filename)" : filename
    }
}

/// A slot whose bytes have landed, ready to be named in a message.
public struct UploadedAttachment: Sendable {
    public var id: String
    public var filename: String
    public var uploadedFilename: String
    public var altText: String?
    /// The type the file was chosen as — Discord's `original_content_type`,
    /// which says "image/heic" for a picture its client sent as a JPEG.
    public var originalContentType: String?
    /// The clip half, written again on the message's attachment entry as
    /// Discord's own does.
    public var clip: ClipUpload?

    public init(
        id: String,
        filename: String,
        uploadedFilename: String,
        altText: String? = nil,
        originalContentType: String? = nil,
        clip: ClipUpload? = nil
    ) {
        self.id = id
        self.filename = filename
        self.uploadedFilename = uploadedFilename
        self.altText = altText
        self.originalContentType = originalContentType
        self.clip = clip
    }
}

extension DiscordREST {

    /// Step one: ask for somewhere to put the bytes.
    ///
    /// Every file in one request, because Discord answers for all of them at
    /// once and a per-file round trip would be a rate-limit bucket spent per
    /// picture in a five-picture message.
    public func createUploadSlots(
        in channelID: ChannelID,
        for files: [UploadRequest]
    ) async throws -> [UploadSlot] {
        struct Body: Encodable {
            struct File: Encodable {
                var filename: String
                var file_size: Int
                var id: String
                /// Present and false rather than absent: a clip is a different
                /// object with a different default size limit, and Discord reads
                /// this key to decide which.
                var is_clip = false
                /// A clip's own fields, as `getUploadPayload` writes them.
                var clip: ClipFields?

                enum CodingKeys: String, CodingKey { case filename, file_size, id, is_clip }

                func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(filename, forKey: .filename)
                    try container.encode(file_size, forKey: .file_size)
                    try container.encode(id, forKey: .id)
                    try container.encode(is_clip, forKey: .is_clip)
                    try clip?.encode(to: encoder)
                }
            }
            var files: [File]
        }
        struct Response: Decodable {
            struct Slot: Decodable {
                var id: Int
                var upload_url: String
                var upload_filename: String
            }
            var attachments: [Slot]
        }

        let body = Body(files: files.enumerated().map { index, file in
            Body.File(
                filename: file.wireFilename,
                file_size: file.size,
                id: String(index),
                is_clip: file.clip != nil,
                clip: file.clip.map(ClipFields.init)
            )
        })
        let response = try await post(
            "/channels/\(channelID.rawValue)/attachments",
            route: "channels/{id}/attachments",
            body: body,
            as: Response.self
        )
        // Matched back to the request by the placeholder id rather than by
        // position: the answer is documented as carrying the id, and trusting
        // array order for a correspondence the server states explicitly is how
        // two files swap names.
        return try response.attachments.map { slot in
            guard slot.id >= 0, slot.id < files.count else {
                throw Failure.decoding("upload slot id \(slot.id) is outside the request")
            }
            guard let url = URL(string: slot.upload_url) else {
                throw Failure.decoding("upload slot \(slot.id) has no usable url")
            }
            return UploadSlot(
                id: String(slot.id),
                uploadURL: url,
                uploadedFilename: slot.upload_filename,
                filename: files[slot.id].wireFilename
            )
        }
    }

    /// Step two: put the bytes there.
    ///
    /// **Nothing of Discord's goes on this request.** The URL is pre-signed for
    /// Google Cloud Storage and carries its own authorisation in the query, so
    /// attaching the account's token would send the credential to a third party
    /// for no reason — and `metadata.apply` would also add a super-properties
    /// header the signature does not cover.
    ///
    /// Streamed from the file rather than read into `Data`: a 500 MiB video read
    /// whole is 500 MiB resident before a byte leaves, and `URLSession`'s upload
    /// task peaks at a buffer instead.
    ///
    /// - Parameter onProgress: Fractional, 0...1, on an arbitrary thread.
    public func upload(
        _ file: URL,
        to slot: UploadSlot,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        var request = URLRequest(url: slot.uploadURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let delegate = onProgress.map(UploadProgressDelegate.init(onProgress:))
        let response: URLResponse
        do {
            (_, response) = try await session.upload(
                for: request, fromFile: file, delegate: delegate
            )
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("no HTTP response from the upload host")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Not `apiFailure`: the body is Google's XML, not Discord's error
            // envelope, and decoding it as one would report a nil code beside a
            // misleading message.
            throw Failure.api(
                status: http.statusCode,
                code: nil,
                message: "the upload host refused the file"
            )
        }
    }

    /// Reports an upload's progress without holding the response.
    ///
    /// `@unchecked Sendable`: the one stored property is a `Sendable` closure
    /// assigned at construction and never written again, and `URLSession` calls
    /// the delegate on its own queue.
    private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Double) -> Void

        init(onProgress: @escaping @Sendable (Double) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didSendBodyData bytesSent: Int64,
            totalBytesSent: Int64,
            totalBytesExpectedToSend: Int64
        ) {
            guard totalBytesExpectedToSend > 0 else { return }
            onProgress(
                min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
            )
        }
    }
}

// MARK: - Links that have run out

extension DiscordREST {
    /// Fresh signatures for attachment links that have expired or are about
    /// to — Discord's `POST /attachments/refresh-urls`, which its client calls
    /// for a link whose `ex` is less than an hour away (module `679164`).
    ///
    /// - Returns: each link Discord answered for, keyed by the link as it was
    ///   asked. A link it did not answer for is left out, and the caller keeps
    ///   the one it had.
    public func refreshAttachmentURLs(_ urls: [String]) async throws -> [String: String] {
        struct Body: Encodable { var attachment_urls: [String] }
        struct Reply: Decodable {
            var refreshed_urls: [Pair]
            struct Pair: Decodable {
                var original: String
                var refreshed: String?
            }
        }
        let reply = try await post(
            "/attachments/refresh-urls",
            route: "attachments/refresh-urls",
            body: Body(attachment_urls: urls),
            as: Reply.self
        )
        var refreshed: [String: String] = [:]
        for pair in reply.refreshed_urls {
            if let fresh = pair.refreshed { refreshed[pair.original] = fresh }
        }
        return refreshed
    }
}
