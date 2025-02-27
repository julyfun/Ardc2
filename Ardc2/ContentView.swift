import SwiftUI
import ARKit
import RealityKit

struct ContentView: View {
    @State private var isARActive = false
    @State private var poseInfo: String = ""
    
    var body: some View {
        ZStack {
            if isARActive {
                ARViewContainer(poseInfo: $poseInfo)
                    .edgesIgnoringSafeArea(.all)
                Text(poseInfo)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                    .position(x: UIScreen.main.bounds.width/2, y: 100)
            }
            
            Button(action: {
                isARActive.toggle()
            }) {
                Text(isARActive ? "关闭AR" : "打开AR")
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            .position(x: UIScreen.main.bounds.width/2, y: UIScreen.main.bounds.height - 100)
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    @Binding var poseInfo: String
    
    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.session.delegate = context.coordinator
        let configuration = ARWorldTrackingConfiguration()
        arView.session.run(configuration)
        return arView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, ARSessionDelegate {
        var parent: ARViewContainer
        
        init(_ parent: ARViewContainer) {
            self.parent = parent
        }
        
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let transform = frame.camera.transform
            parent.poseInfo = """
                位置: X: \(String(format: "%.2f", transform.columns.3.x))
                     Y: \(String(format: "%.2f", transform.columns.3.y))
                     Z: \(String(format: "%.2f", transform.columns.3.z))
                """
        }
    }
}

