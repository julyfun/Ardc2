import ARKit
import AVFoundation
import RealityKit
import simd
import SwiftBSON
import SwiftUI
import Compression
import Tarscape
import Foundation
import UIKit
import DataCompression

struct FramesData {
    var arkitPose: [[Float32]] // n * 7
    var gripperPoses: [[[Float32]]] // n * 2 * 7
    var gripperWidth: [Float32] // n
    var timestamps: [Float32] // n

    init() {
        arkitPose = []
        gripperPoses = []
        gripperWidth = []
        timestamps = []
    }

    func toBSON() -> BSON {
        var doc = BSONDocument()

        // doc["depthMap"] = .array(depthMap.map { .array($0.map { .array($0.map { .double(Double($0)) }) }) })

        // Convert arkitPose (n * 7)
        doc["arkitPose"] = .array(arkitPose.map { .array($0.map { .double(Double($0)) }) })

        // Convert gripperPoses (n * 2 * 7)
        doc["gripperPoses"] = .array(gripperPoses.map { frame in
            .array(frame.map { pose in
                .array(pose.map { .double(Double($0)) })
            })
        })

        // Convert scalar values
        doc["gripperWidth"] = .array(gripperWidth.map { .double(Double($0)) })
        doc["timestamps"] = .array(timestamps.map { .double(Double($0)) })

        return .document(doc)
    }
}

struct DepthMapFileInfo {
    let url: URL
    let fileName: String
    let fileSize: Int64
    let frameCount: Int
    
    init(url: URL, frameCount: Int = 0) {
        self.url = url
        self.fileName = url.lastPathComponent
        self.frameCount = frameCount
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            self.fileSize = attributes[.size] as? Int64 ?? 0
        } catch {
            self.fileSize = 0
        }
    }
}

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
        
        createNewFile()
    }
    
    private func createNewFile() {
        // 关闭之前的文件
        if let file = self.file {
            file.closeFile()
            self.file = nil
        }

        // 释放之前的压缩器
        if let compressorPtr = self.compressorPtr {
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
                self.createNewFile()
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

struct ContentView: View {
    @State private var poseInfo: String = ""
    @State private var isRecording = false
    @State private var isRecordingComplete = false
    @State private var frameCount = 0
    @State private var videoFileSize: Int64 = 0
    @State private var depthMapFiles: [DepthMapFileInfo] = []
    @State private var currentPosition: simd_float3 = simd_float3(0, 0, 0)
    @State private var imageResolution: CGSize = .zero
    @State private var depthResolution: CGSize = .zero
    @State private var bsonFileSize: Int64 = 0
    @State private var bsonFileSizeError: Bool = false
    @State private var showCompletionInfo: Bool = false
    @State private var recordingStartTime: Date?
    @State private var recordingEndTime: Date?
    @State private var yamlFileURL: URL?
    @State private var yamlFileSize: Int64 = 0
    @State private var yamlContent: String = ""
    @State private var yamlContentError: Bool = false
    @State private var outputDirectory: URL?
    @State private var tarGzFileSize: Int64 = 0
    @State private var tarGzFilePath: String = ""

    private let videoWriter: VideoWriter = {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording.mp4")
        return VideoWriter(fileURL: fileURL)
    }()
    
    private let depthMapRecorder = DepthMapRecorder()

    @State private var framesData = FramesData()

    // 创建输出目录
    private func createOutputDirectory() -> URL? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())
        
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputDirectory = documentsDirectory.appendingPathComponent(timestamp)
        
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)
            return outputDirectory
        } catch {
            print("创建输出目录失败: \(error.localizedDescription)")
            return nil
        }
    }

    // 更新BSON文件大小信息
    private func updateBSONFileSize() {
        let bsonFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("frame_data.bson")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: bsonFileURL.path)
            if let size = attributes[.size] as? Int64 {
                bsonFileSize = size
                bsonFileSizeError = false
            } else {
                bsonFileSizeError = true
            }
        } catch {
            bsonFileSizeError = true
        }
    }
    
    // 生成YAML文件
    private func generateYAMLFile() {
        guard let startTime = recordingStartTime,
              let endTime = recordingEndTime,
              let outputDir = outputDirectory else { return }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let date = dateFormatter.string(from: startTime)
        
        dateFormatter.dateFormat = "HH:mm:ss"
        let time = dateFormatter.string(from: startTime)
        
        let recordingDuration = endTime.timeIntervalSince(startTime)
        
        // 获取设备信息
        let device = UIDevice.current
        let deviceName = device.name
        let deviceModel = device.model
        let systemName = device.systemName
        let systemVersion = device.systemVersion
        let deviceIdentifier = device.identifierForVendor?.uuidString ?? "未知"
        
        // 构建YAML内容
        let yamlContent = """
        date: \(date)
        time: \(time)
        length: \(String(format: "%.2f", recordingDuration))
        video:
          num_frames: \(frameCount)
          height: \(Int(imageResolution.height))
          width: \(Int(imageResolution.width))
          file_size: \(ByteCountFormatter.string(fromByteCount: videoFileSize, countStyle: .file))
        task_description: "AR深度图录制"
        task_id: 1
        user: "\(deviceName)"
        device:
          name: "\(deviceName)"
          model: "\(deviceModel)"
          system: "\(systemName)"
          version: "\(systemVersion)"
          identifier: "\(deviceIdentifier)"
        depth_map:
          height: \(Int(depthResolution.height))
          width: \(Int(depthResolution.width))
          max_num_frames: \(depthMapRecorder.maxNumberOfFrames)
          files:
        """
        
        // 添加深度图文件信息
        var yamlWithDepthFiles = yamlContent
        for (index, fileInfo) in depthMapFiles.enumerated() {
            yamlWithDepthFiles += "\n    - file_\(index):"
            yamlWithDepthFiles += "\n        name: \"\(fileInfo.fileName)\""
            yamlWithDepthFiles += "\n        size: \"\(ByteCountFormatter.string(fromByteCount: fileInfo.fileSize, countStyle: .file))\""
            yamlWithDepthFiles += "\n        num_frames: \(fileInfo.frameCount)"
        }
        
        // 添加BSON文件信息
        yamlWithDepthFiles += "\nbson_data:"
        if !bsonFileSizeError {
            yamlWithDepthFiles += "\n  size: \"\(ByteCountFormatter.string(fromByteCount: bsonFileSize, countStyle: .file))\""
        } else {
            yamlWithDepthFiles += "\n  size: \"未知\""
        }
        
        // 保存YAML文件
        let yamlFileURL = outputDir.appendingPathComponent("recording_info.yaml")
        do {
            try yamlWithDepthFiles.write(to: yamlFileURL, atomically: true, encoding: .utf8)
            
            // 获取YAML文件大小
            let attributes = try FileManager.default.attributesOfItem(atPath: yamlFileURL.path)
            if let size = attributes[.size] as? Int64 {
                self.yamlFileSize = size
            }
            
            self.yamlFileURL = yamlFileURL
            
            // 读取YAML内容到状态变量
            self.yamlContent = try String(contentsOf: yamlFileURL, encoding: .utf8)
            self.yamlContentError = false
        } catch {
            print("YAML文件操作失败: \(error.localizedDescription)")
            self.yamlContentError = true
        }
    }

    private func createTarGzArchive() {
        guard let outputDir = outputDirectory else { return }

        let tarURL = outputDir.appendingPathComponent("recording_archive.tar")
        let tarGzURL = outputDir.appendingPathComponent("recording_archive.tar.gz")

        do {
            // 创建tar文件
            try FileManager.default.createTar(at: tarURL, from: outputDir)
            
            // 读取tar文件数据
            let tarData = try Data(contentsOf: tarURL)
            
            // 创建gzip压缩数据
            guard let gzippedData = tarData.gzip() else {
                print("Gzip压缩失败")
                return
            }
            
            // 写入tar.gz文件
            try gzippedData.write(to: tarGzURL)
            
            // 删除原始tar文件
            try FileManager.default.removeItem(at: tarURL)
            
            // 更新压缩文件信息
            let attributes = try FileManager.default.attributesOfItem(atPath: tarGzURL.path)
            tarGzFileSize = attributes[.size] as? Int64 ?? 0
            tarGzFilePath = tarGzURL.path
            
            print("打包完成，文件大小: \(ByteCountFormatter.string(fromByteCount: tarGzFileSize, countStyle: .file))")
            print("文件路径: \(tarGzURL)")
        } catch {
            print("打包失败: \(error.localizedDescription)")
        }
    }

    var body: some View {
        ZStack {
            // AR视图
            ARViewContainer(
                poseInfo: $poseInfo,
                isRecording: $isRecording,
                isRecordingComplete: $isRecordingComplete,
                frameCount: $frameCount,
                framesData: $framesData,
                videoWriter: videoWriter,
                depthMapRecorder: depthMapRecorder,
                currentPosition: $currentPosition,
                imageResolution: $imageResolution,
                depthResolution: $depthResolution
            )
            .edgesIgnoringSafeArea(.all)
            
            // 主界面布局
            VStack(spacing: 0) {
                // 顶部信息栏
                VStack(spacing: 4) {
                    HStack {
                        Text("位置 (m):")
                            .font(.system(size: 12, weight: .medium))
                        Text(String(format: "X: %.2f  Y: %.2f  Z: %.2f", currentPosition.x, currentPosition.y, currentPosition.z))
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    
                    HStack {
                        Text("分辨率:")
                            .font(.system(size: 12, weight: .medium))
                        Text(String(format: "相机: %.0f×%.0f  深度图: %.0f×%.0f", 
                                    imageResolution.width, imageResolution.height,
                                    depthResolution.width, depthResolution.height))
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    
                    if isRecording {
                        HStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                            Text("正在录制 - 帧数: \(frameCount)")
                                .font(.system(size: 12, weight: .bold))
                            Spacer()
                        }
                    }
                }
                .padding(8)
                .background(Color.black.opacity(0.6))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                
                // 中间空间用于AR视图
                Spacer()
                
                // 底部控制栏
                VStack(spacing: 10) {
                    Button(action: {
                        isRecording.toggle()
                        if isRecording {
                            // 创建新的输出目录
                            outputDirectory = createOutputDirectory()
                            guard let outputDir = outputDirectory else {
                                print("无法创建输出目录")
                                isRecording = false
                                return
                            }
                            
                            // 开始录制
                            recordingStartTime = Date()
                            let videoURL = outputDir.appendingPathComponent("recording.mp4")
                            videoWriter.updateFileURL(videoURL)
                            videoWriter.startRecording()
                            depthMapRecorder.updateOutputDirectory(outputDir)
                            depthMapRecorder.startRecording()
                            frameCount = 0
                            isRecordingComplete = false
                            showCompletionInfo = false
                        } else {
                            // 结束录制
                            recordingEndTime = Date()
                            videoWriter.stopRecording { _, size in
                                videoFileSize = size
                                
                                depthMapRecorder.finishRecording { files in
                                    depthMapFiles = files
                                    
                                    guard let outputDir = outputDirectory else { return }
                                    let bsonData = framesData.toBSON()
                                    let bsonFileURL = outputDir.appendingPathComponent("frame_data.bson")

                                    do {
                                        let bsonBytes = try BSONEncoder().encode(bsonData)
                                        let bsonDataToWrite = bsonBytes.toData()
                                        try bsonDataToWrite.write(to: bsonFileURL)
                                        
                                        // 更新BSON文件大小信息
                                        self.updateBSONFileSize()
                                    } catch {
                                        print("BSON保存失败: \(error.localizedDescription)")
                                        bsonFileSizeError = true
                                    }
                                    
                                    // 生成YAML元信息文件
                                    self.generateYAMLFile()
                                    
                                    // 创建tar.gz存档
                                    self.createTarGzArchive()
                                    
                                    isRecordingComplete = true
                                    showCompletionInfo = true
                                }
                            }
                        }
                    }) {
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 3)
                                .frame(width: 70, height: 70)
                            
                            Circle()
                                .fill(isRecording ? Color.white : Color.red)
                                .frame(width: isRecording ? 30 : 60, height: isRecording ? 30 : 60)
                        }
                    }
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.6))
            }
            
            // 录制完成信息悬浮窗
            if showCompletionInfo {
                VStack {
                    Spacer()
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("🎥 录制完成")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                
                                Spacer()
                                
                                Button(action: {
                                    showCompletionInfo = false
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.white)
                                        .font(.system(size: 20))
                                }
                            }
                            
                            if let startTime = recordingStartTime, let endTime = recordingEndTime {
                                let duration = endTime.timeIntervalSince(startTime)
                                Text("录制时长: \(String(format: "%.2f", duration)) 秒")
                            }
                            
                            Text("帧数: \(frameCount)")
                            Text("视频文件大小: \(ByteCountFormatter.string(fromByteCount: videoFileSize, countStyle: .file))")
                            
                            // 使用状态变量显示BSON文件大小
                            Text(bsonFileSizeError ? 
                                "无法获取BSON文件大小" : 
                                "BSON文件大小: \(ByteCountFormatter.string(fromByteCount: bsonFileSize, countStyle: .file))")
                            
                            // 显示YAML文件信息
                            if let _ = yamlFileURL {
                                Text("YAML元信息文件大小: \(ByteCountFormatter.string(fromByteCount: yamlFileSize, countStyle: .file))")
                            }
                            
                            Text("深度图文件:")
                                .font(.headline)
                                .padding(.top, 5)
                            
                            // 深度图文件表格
                            VStack(spacing: 4) {
                                HStack {
                                    Text("文件名")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fontWeight(.bold)
                                    Text("帧数 | 大小")
                                        .frame(width: 150, alignment: .trailing)
                                        .fontWeight(.bold)
                                }
                                .padding(.horizontal, 5)
                                
                                Divider()
                                    .background(Color.white.opacity(0.5))
                                
                                ForEach(depthMapFiles, id: \.fileName) { fileInfo in
                                    HStack {
                                        Text(fileInfo.fileName)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text("\(fileInfo.frameCount)帧 | \(ByteCountFormatter.string(fromByteCount: fileInfo.fileSize, countStyle: .file))")
                                            .frame(width: 150, alignment: .trailing)
                                    }
                                    .padding(.horizontal, 5)
                                    
                                    Divider()
                                        .background(Color.white.opacity(0.5))
                                }
                            }
                            
                            // YAML文件全文显示
                            if let _ = yamlFileURL {
                                Text("YAML元信息文件内容:")
                                    .font(.headline)
                                    .padding(.top, 10)
                                
                                if yamlContentError {
                                    Text("无法读取YAML文件内容")
                                        .foregroundColor(.red)
                                } else {
                                    Text(yamlContent)
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                        .background(Color.black.opacity(0.3))
                                        .cornerRadius(5)
                                }
                            }
                            
                            if tarGzFileSize > 0 {
                                Text("压缩包大小: \(ByteCountFormatter.string(fromByteCount: tarGzFileSize, countStyle: .file))")
                                Text("保存路径: \(tarGzFilePath)")
                                    .font(.system(size: 11))
                            }
                        }
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(10)
                        .padding()
                    }
                    .frame(maxHeight: 300)
                    .onTapGesture {
                        showCompletionInfo = false
                    }
                }
            }
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    @Binding var poseInfo: String
    @Binding var isRecording: Bool
    @Binding var isRecordingComplete: Bool
    @Binding var frameCount: Int
    @Binding var framesData: FramesData
    let videoWriter: VideoWriter
    let depthMapRecorder: DepthMapRecorder
    @Binding var currentPosition: simd_float3
    @Binding var imageResolution: CGSize
    @Binding var depthResolution: CGSize

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.session.delegate = context.coordinator

        // Check if AR is supported
        guard ARWorldTrackingConfiguration.isSupported else {
            poseInfo = "⚠️ 设备不支持AR功能"
            return arView
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]

        // 开启深度图，不开不录
        if type(of: configuration).supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
            print("支持深度图")
        } else {
            print("⚠️ 设备不支持深度图")
        }

        arView.session.run(configuration)

        return arView
    }

    func updateUIView(_: ARView, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}

class Coordinator: NSObject, ARSessionDelegate {
    var parent: ARViewContainer

    init(_ parent: ARViewContainer) {
        self.parent = parent
    }

    func session(_: ARSession, didUpdate frame: ARFrame) {
        // 更新位置信息，无论是否在录制
        let transform = frame.camera.transform
        parent.currentPosition = simd_float3(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        parent.imageResolution = frame.camera.imageResolution
        
        if let depthData = frame.sceneDepth {
            let depthMap = depthData.depthMap
            parent.depthResolution = CGSize(
                width: CVPixelBufferGetWidth(depthMap),
                height: CVPixelBufferGetHeight(depthMap)
            )
        }
        
        if parent.isRecording {
            parent.frameCount += 1
            parent.videoWriter.write(frame: frame)

            // 记录深度图
            if let depthData = frame.sceneDepth {
                let depthMap = depthData.depthMap
                parent.depthMapRecorder.addDepthMap(depthMap)
            }

            // Collect frame data
            let rotationMatrix = simd_float3x3(
                simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )
            let quaternion = simd_quatf(rotationMatrix)
            let arkitPose: [Float32] = [
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z,
                quaternion.vector.x,
                quaternion.vector.y,
                quaternion.vector.z,
                quaternion.vector.w,
            ]

            let gripperPoses: [[Float32]] = [
                [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0],
                [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0],
            ]
            let gripperWidth: Float32 = 0.0 // Default width
            let timestamp = Float32(frame.timestamp) // Current frame timestamp

            parent.framesData.arkitPose.append(arkitPose)
            parent.framesData.gripperPoses.append(gripperPoses)
            parent.framesData.gripperWidth.append(gripperWidth)
            parent.framesData.timestamps.append(timestamp)
        }
    }
}
