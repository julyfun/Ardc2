import ARKit
import AVFoundation
import Compression
import DataCompression
import Foundation
import RealityKit
import simd
import SwiftBSON
import SwiftUI
import Tarscape
import UIKit

class DepthMapRecorder {
    let maxNumberOfFrames = 250
    private var frameCount: Int = 0
    private var outputFiles: [URL] = []
    private var fileFrameCounts: [URL: Int] = [:]
    private var currentFileIndex: Int = 0
    private var processingQueue = DispatchQueue(label: "depthMapProcessing", qos: .userInteractive)
    private var outputDirectory: URL?

    // [压缩相关]
    private var compressorPtr: UnsafeMutablePointer<compression_stream>?
    private var dstBuffer: UnsafeMutablePointer<UInt8>?
    private var bufferSize: Int
    private var file: FileHandle?
    private var currentOutputURL: URL?

    init() {
        // [NOTE] 此处假设分辨率为256x192
        bufferSize = 256 * 192 * 2 * maxNumberOfFrames
    }

    func updateOutputDirectory(_ directory: URL) {
        outputDirectory = directory
    }

    func prepareForRecording() {
        frameCount = 0
        currentFileIndex = 0
        outputFiles.removeAll()

        createNewFileForDepth()
    }

    private func createNewFileForDepth() {
        // 关闭之前的文件
        if let file = file {
            file.closeFile()
            self.file = nil
        }

        // 释放之前的压缩器
        if let compressorPtr = compressorPtr {
            compression_stream_destroy(compressorPtr)
            self.compressorPtr = nil
        }

        // 创建新文件
        let fileName = "depth_map_\(currentFileIndex).depth"
        if let outputDir = outputDirectory {
            currentOutputURL = outputDir.appendingPathComponent(fileName)
        } else {
            currentOutputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        }

        if let url = currentOutputURL {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
            file = FileHandle(forUpdatingAtPath: url.path)

            if file != nil {
                outputFiles.append(url)
                fileFrameCounts[url] = 0

                // 初始化压缩对象
                compressorPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
                compression_stream_init(compressorPtr!, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
                dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                compressorPtr!.pointee.dst_ptr = dstBuffer!
                compressorPtr!.pointee.dst_size = bufferSize

                currentFileIndex += 1
            } else {
                print("无法创建文件: \(url.path)")
            }
        }
    }

    func startRecording() {
        processingQueue.async {
            self.prepareForRecording()
        }
    }

    func addDepthMap(_ depthMap: CVPixelBuffer) {
        processingQueue.async {
            if self.frameCount >= self.maxNumberOfFrames {
                // 缓冲区已满，刷新并创建新文件
                self.flush()
                self.createNewFileForDepth()
                self.frameCount = 0
            }

            guard let compressorPtr = self.compressorPtr, let file = self.file else { return }

            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            if let baseAddress = CVPixelBufferGetBaseAddress(depthMap) {
                compressorPtr.pointee.src_ptr = UnsafePointer<UInt8>(baseAddress.assumingMemoryBound(to: UInt8.self))
                let height = CVPixelBufferGetHeight(depthMap)
                compressorPtr.pointee.src_size = CVPixelBufferGetBytesPerRow(depthMap) * height

                let flags = Int32(0)
                let compressionStatus = compression_stream_process(compressorPtr, flags)

                if compressionStatus != COMPRESSION_STATUS_OK {
                    print("深度图压缩失败: \(compressionStatus)")
                    return
                }

                if compressorPtr.pointee.src_size != 0 {
                    print("压缩库未处理所有数据")
                    return
                }

                self.frameCount += 1

                // 更新当前文件的帧数
                if let url = self.currentOutputURL {
                    self.fileFrameCounts[url] = (self.fileFrameCounts[url] ?? 0) + 1
                }
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }
    }

    private func flush() {
        guard let compressorPtr = compressorPtr, let dstBuffer = dstBuffer, let file = file else { return }

        let bytesWritten = bufferSize - compressorPtr.pointee.dst_size
        let data = Data(bytesNoCopy: dstBuffer, count: Int(bytesWritten), deallocator: .none)
        file.write(data)
    }

    func finishRecording(completion: @escaping ([DepthMapFileInfo]) -> Void) {
        processingQueue.async {
            guard let compressorPtr = self.compressorPtr else {
                DispatchQueue.main.async {
                    let fileInfos = self.outputFiles.map { DepthMapFileInfo(url: $0, frameCount: self.fileFrameCounts[$0] ?? 0) }
                    completion(fileInfos)
                }
                return
            }

            // 完成压缩
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            compressorPtr.pointee.src_size = 0
            let compressionStatus = compression_stream_process(compressorPtr, flags)

            if compressionStatus != COMPRESSION_STATUS_END {
                print("完成压缩失败: \(compressionStatus)")
            }

            // 刷新最后的数据
            self.flush()

            // 关闭文件
            if let file = self.file {
                file.closeFile()
                self.file = nil
            }

            if let compressorPtr = self.compressorPtr {
                compression_stream_destroy(compressorPtr)
                self.compressorPtr = nil
            }

            if let dstBuffer = self.dstBuffer {
                dstBuffer.deallocate()
                self.dstBuffer = nil
            }

            DispatchQueue.main.async {
                let fileInfos = self.outputFiles.map { DepthMapFileInfo(url: $0, frameCount: self.fileFrameCounts[$0] ?? 0) }
                completion(fileInfos)
            }
        }
    }

    deinit {
        if let file = file {
            file.closeFile()
        }

        if let compressorPtr = compressorPtr {
            compression_stream_destroy(compressorPtr)
        }

        if let dstBuffer = dstBuffer {
            dstBuffer.deallocate()
        }
    }
}
