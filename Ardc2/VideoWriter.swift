import ARKit
import AVFoundation

class VideoWriter {
    private let fileURL: URL
    private var videoWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func startRecording() {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {}

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
        ]

        videoWriter = try? AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)

        guard let videoWriter = videoWriter,
              let videoWriterInput = videoWriterInput else { return }

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
        ]

        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        if videoWriter.canAdd(videoWriterInput) {
            videoWriter.add(videoWriterInput)
        }

        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: CMTime.zero)
    }

    func stopRecording(completion: @escaping (URL, Int64) -> Void) {
        guard let videoWriter = videoWriter,
              let videoWriterInput = videoWriterInput else { return }

        videoWriterInput.markAsFinished()
        videoWriter.finishWriting {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: self.fileURL.path)[.size] as? Int64) ?? 0
            completion(self.fileURL, fileSize)
        }
    }

    func write(frame: ARFrame) {
        guard let pixelBufferAdaptor = pixelBufferAdaptor,
              let videoWriterInput = videoWriterInput,
              videoWriterInput.isReadyForMoreMediaData else { return }

        let pixelBuffer = frame.capturedImage
        let time = CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000_000)

        pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: time)
    }
}
