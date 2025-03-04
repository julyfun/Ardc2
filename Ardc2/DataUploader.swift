import Foundation
import UIKit

class DataUploader: NSObject, URLSessionDelegate {
    // 服务器URL
    private let serverURL: String
    // 会话配置
    private var session: URLSession!
    
    // 上传状态回调
    typealias UploadCompletionHandler = (Bool, String) -> Void
    
    // 初始化上传器
    init(serverURL: String = "https://47.103.61.134:4443") {
        self.serverURL = serverURL
        super.init()
        
        // 创建自定义会话配置，允许自签名证书
        let configuration = URLSessionConfiguration.default
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    
    // 处理SSL证书验证
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // 对于自签名证书，我们接受所有服务器证书
        // 注意：在生产环境中，应该实现更严格的证书验证
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    
    // 测试服务器连接
    func testConnection(completion: @escaping UploadCompletionHandler) {
        guard let url = URL(string: serverURL) else {
            completion(false, "无效的服务器URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, "连接错误: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(false, "无效的响应")
                return
            }
            
            let responseText = data != nil ? String(data: data!, encoding: .utf8) ?? "无响应内容" : "无响应内容"
            completion(httpResponse.statusCode == 200, "状态码: \(httpResponse.statusCode), 响应: \(responseText)")
        }
        
        task.resume()
    }
    
    // 上传文件
    func uploadFile(fileURL: URL, completion: @escaping UploadCompletionHandler) {
        guard let uploadURL = URL(string: "\(serverURL)/upload") else {
            completion(false, "无效的上传URL")
            return
        }
        
        // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            completion(false, "文件不存在: \(fileURL.path)")
            return
        }
        
        // 创建上传请求
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        
        // 生成唯一的边界字符串
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // 创建multipart表单数据
        let fileName = fileURL.lastPathComponent
        
        var body = Data()
        
        // 添加文件数据
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        
        // 根据文件类型设置Content-Type
        let mimeType = mimeTypeForPath(path: fileURL.path)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        
        do {
            // 读取文件数据
            let fileData = try Data(contentsOf: fileURL)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
            
            // 添加结束边界
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            
            // 创建上传任务
            let task = session.uploadTask(with: request, from: body) { data, response, error in
                if let error = error {
                    completion(false, "上传错误: \(error.localizedDescription)")
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(false, "无效的响应")
                    return
                }
                
                let responseText = data != nil ? String(data: data!, encoding: .utf8) ?? "无响应内容" : "无响应内容"
                let success = (200...299).contains(httpResponse.statusCode)
                completion(success, "状态码: \(httpResponse.statusCode), 响应: \(responseText)")
            }
            
            task.resume()
        } catch {
            completion(false, "读取文件错误: \(error.localizedDescription)")
        }
    }
    
    // 上传tar.gz文件
    func uploadTarGzFile(tarGzURL: URL, completion: @escaping UploadCompletionHandler) {
        uploadFile(fileURL: tarGzURL, completion: completion)
    }
    
    // 获取文件的MIME类型
    private func mimeTypeForPath(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let pathExtension = url.pathExtension
        
        switch pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "mp4":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        case "tar":
            return "application/x-tar"
        case "gz":
            return "application/gzip"
        case "tar.gz", "tgz":
            return "application/x-gzip"
        case "bson":
            return "application/bson"
        case "yaml", "yml":
            return "application/x-yaml"
        default:
            return "application/octet-stream"
        }
    }
}

// 扩展示例：使用方法
extension DataUploader {
    // 上传录制的数据包
    static func uploadRecordingPackage(tarGzPath: String, completion: @escaping (Bool, String) -> Void) {
        let uploader = DataUploader()
        let fileURL = URL(fileURLWithPath: tarGzPath)
        
        // 先测试连接
        uploader.testConnection { success, message in
            if success {
                print("服务器连接成功: \(message)")
                // 连接成功后上传文件
                uploader.uploadTarGzFile(tarGzURL: fileURL, completion: completion)
            } else {
                print("服务器连接失败: \(message)")
                completion(false, "服务器连接失败: \(message)")
            }
        }
    }
} 
