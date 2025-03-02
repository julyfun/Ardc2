import ARKit
import AVFoundation
import RealityKit
import simd
import SwiftBSON
import SwiftUI

struct FramesData {
    var depthMap: [[[Float16]]] // n * h * w
    var arkitPose: [[Float32]] // n * 7
    var gripperPoses: [[[Float32]]] // n * 2 * 7
    var gripperWidth: [Float32] // n
    var timestamps: [Float32] // n

    init() {
        depthMap = []
        arkitPose = []
        gripperPoses = []
        gripperWidth = []
        timestamps = []
    }

    func toBSON() -> BSON {
        var doc = BSONDocument()

        doc["depthMap"] = .array(depthMap.map { .array($0.map { .array($0.map { .double(Double($0)) }) }) })

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

struct ContentView: View {
    @State private var poseInfo: String = ""
    @State private var isRecording = false
    @State private var isRecordingComplete = false
    @State private var frameCount = 0
    @State private var videoFileSize: Int64 = 0

    private let videoWriter: VideoWriter = {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording.mp4")
        return VideoWriter(fileURL: fileURL)
    }()

    @State private var framesData = FramesData()

    var body: some View {
        ZStack {
            ARViewContainer(
                poseInfo: $poseInfo,
                isRecording: $isRecording,
                isRecordingComplete: $isRecordingComplete,
                frameCount: $frameCount,
                framesData: $framesData,
                videoWriter: videoWriter
            )
            .edgesIgnoringSafeArea(.all)
            VStack {
                Text(poseInfo)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                    .padding(.top, 40)

                Spacer()

                Button(action: {
                    isRecording.toggle()
                    if isRecording {
                        videoWriter.startRecording()
                        frameCount = 0
                    } else {
                        videoWriter.stopRecording { _, size in
                            videoFileSize = size
                            isRecordingComplete = true

                            // Save BSON data
                            let bsonData = framesData.toBSON()
                            let bsonFileURL = FileManager.default.temporaryDirectory
                                .appendingPathComponent("frame_data.bson")

                            do {
                                let bsonBytes = try BSONEncoder().encode(bsonData)

                                poseInfo = """
                                🎥 录制完成
                                帧数: \(frameCount)
                                文件大小: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                BSON数据已保存
                                """
                            } catch {
                                poseInfo = """
                                🎥 录制完成
                                帧数: \(frameCount)
                                文件大小: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                ❌ BSON保存失败: \(error.localizedDescription)
                                """
                            }
                        }
                    }
                }) {
                    Text(isRecording ? "结束" : "录制")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .padding()
                        .background(isRecording ? Color.red : Color.blue)
                        .cornerRadius(10)
                }
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity)
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

        do {
            try arView.session.run(configuration)
        } catch {
            poseInfo = "❌ AR会话启动失败: \(error.localizedDescription)"
        }

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
        if parent.isRecording {
            parent.frameCount += 1
            parent.videoWriter.write(frame: frame)

            // Collect frame data
            // Convert depth map to Float16 array
            var depthMapArray: [[Float16]] = []
            if let depthMap = frame.capturedDepthData?.depthDataMap {
                let width = CVPixelBufferGetWidth(depthMap)
                let height = CVPixelBufferGetHeight(depthMap)
                CVPixelBufferLockBaseAddress(depthMap, .readOnly)
                if let baseAddress = CVPixelBufferGetBaseAddress(depthMap) {
                    let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
                    for y in 0 ..< height {
                        var row: [Float16] = []
                        for x in 0 ..< width {
                            let index = y * width + x
                            row.append(Float16(floatBuffer[index]))
                        }
                        depthMapArray.append(row)
                    }
                }
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            }

            let transform = frame.camera.transform
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

            parent.framesData.depthMap.append(depthMapArray)
            parent.framesData.arkitPose.append(arkitPose)
            parent.framesData.gripperPoses.append(gripperPoses)
            parent.framesData.gripperWidth.append(gripperWidth)
            parent.framesData.timestamps.append(timestamp)
        }

        if !parent.isRecordingComplete {
            let transform = frame.camera.transform
            let imageResolution = frame.camera.imageResolution
            let x = String(format: "%.2f", transform.columns.3.x)
            let y = String(format: "%.2f", transform.columns.3.y)
            let z = String(format: "%.2f", transform.columns.3.z)
            let width = String(format: "%.0f", imageResolution.width)
            let height = String(format: "%.0f", imageResolution.height)

            parent.poseInfo = """
            🎯 位置信息
            X: \(x) m
            Y: \(y) m
            Z: \(z) m

            📷 相机分辨率
            宽度: \(width) px
            高度: \(height) px
            """
        }
    }
}
