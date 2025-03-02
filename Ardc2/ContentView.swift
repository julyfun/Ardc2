import ARKit
import AVFoundation
import RealityKit
import simd
import SwiftBSON
import SwiftUI
import Compression
import Foundation

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
    
    init(url: URL) {
        self.url = url
        self.fileName = url.lastPathComponent
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            self.fileSize = attributes[.size] as? Int64 ?? 0
        } catch {
            self.fileSize = 0
        }
    }
}

class DepthMapRecorder {
    private let maxNumberOfFrames = 250
    private var frameCount: Int = 0
    private var outputFiles: [URL] = []
    private var currentFileIndex: Int = 0
    private var processingQueue = DispatchQueue(label: "depthMapProcessing", qos: .userInteractive)
    
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
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as NSString
        let fileName = "DepthMap_\(currentFileIndex).depth"
        currentOutputURL = URL(fileURLWithPath: documentsPath.appendingPathComponent(fileName))
        
        if let url = currentOutputURL {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
            file = FileHandle(forUpdatingAtPath: url.path)
            
            if file != nil {
                outputFiles.append(url)
                
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
                    let fileInfos = self.outputFiles.map { DepthMapFileInfo(url: $0) }
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
                let fileInfos = self.outputFiles.map { DepthMapFileInfo(url: $0) }
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

    private let videoWriter: VideoWriter = {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording.mp4")
        return VideoWriter(fileURL: fileURL)
    }()
    
    private let depthMapRecorder = DepthMapRecorder()

    @State private var framesData = FramesData()

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
                            videoWriter.startRecording()
                            depthMapRecorder.startRecording()
                            frameCount = 0
                            isRecordingComplete = false
                            showCompletionInfo = false
                        } else {
                            videoWriter.stopRecording { _, size in
                                videoFileSize = size
                                
                                depthMapRecorder.finishRecording { files in
                                    depthMapFiles = files
                                    
                                    let bsonData = framesData.toBSON()
                                    let bsonFileURL = FileManager.default.temporaryDirectory
                                        .appendingPathComponent("frame_data.bson")

                                    do {
                                        let bsonBytes = try BSONEncoder().encode(bsonData)
                                        // 确保 bsonBytes 不是 nil
                                        let bsonDataToWrite = bsonBytes.toData()
                                        // 将BSON数据写入文件
                                        try bsonDataToWrite.write(to: bsonFileURL)
                                        
                                        // 更新BSON文件大小信息
                                        self.updateBSONFileSize()
                                    } catch {
                                        print("BSON保存失败: \(error.localizedDescription)")
                                        bsonFileSizeError = true
                                    }
                                    
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
                            
                            Text("帧数: \(frameCount)")
                            Text("视频文件大小: \(ByteCountFormatter.string(fromByteCount: videoFileSize, countStyle: .file))")
                            
                            // 使用状态变量显示BSON文件大小
                            Text(bsonFileSizeError ? 
                                "无法获取BSON文件大小" : 
                                "BSON文件大小: \(ByteCountFormatter.string(fromByteCount: bsonFileSize, countStyle: .file))")
                            
                            Text("深度图文件:")
                                .font(.headline)
                                .padding(.top, 5)
                            
                            // 深度图文件表格
                            VStack(spacing: 4) {
                                HStack {
                                    Text("文件名")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fontWeight(.bold)
                                    Text("大小")
                                        .frame(width: 100, alignment: .trailing)
                                        .fontWeight(.bold)
                                }
                                .padding(.horizontal, 5)
                                
                                Divider()
                                    .background(Color.white.opacity(0.5))
                                
                                ForEach(depthMapFiles, id: \.fileName) { fileInfo in
                                    HStack {
                                        Text(fileInfo.fileName)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(ByteCountFormatter.string(fromByteCount: fileInfo.fileSize, countStyle: .file))
                                            .frame(width: 100, alignment: .trailing)
                                    }
                                    .padding(.horizontal, 5)
                                    
                                    Divider()
                                        .background(Color.white.opacity(0.5))
                                }
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
