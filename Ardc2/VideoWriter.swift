import ARKit
import AVFoundation

class VideoWriter {
    private var fileURL: URL
    private var videoWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstTimestamp: Double?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func updateFileURL(_ newURL: URL) {
        self.fileURL = newURL
    }

    func startRecording() {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {}

        firstTimestamp = nil

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10000000, // 10 Mbps
                AVVideoMaxKeyFrameIntervalKey: 30,   // 每秒一个关键帧
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        videoWriter = try? AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput?.expectsMediaDataInRealTime = true

        guard let videoWriter = videoWriter,
              let videoWriterInput = videoWriterInput else { return }

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferMetalCompatibilityKey as String: true
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
            self.firstTimestamp = nil
            completion(self.fileURL, fileSize)
        }
    }

    func write(frame: ARFrame) {
        guard let pixelBufferAdaptor = pixelBufferAdaptor,
              let videoWriterInput = videoWriterInput,
              videoWriterInput.isReadyForMoreMediaData else { return }

        let pixelBuffer = frame.capturedImage
        
        // 处理时间戳
        if firstTimestamp == nil {
            firstTimestamp = frame.timestamp
        }
        
        guard let firstTimestamp = firstTimestamp else { return }
        
        // 计算相对时间（以秒为单位）
        let relativeTime = frame.timestamp - firstTimestamp
        let time = CMTime(seconds: relativeTime, preferredTimescale: 1000000)
        
        pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: time)
    }
}
