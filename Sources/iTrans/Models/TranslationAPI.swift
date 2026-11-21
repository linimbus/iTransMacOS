import Foundation

struct APIConfiguration {
    var baseURL: URL
    var path: String
    var method: String
    var textField: String
    var targetField: String?
    var sourceField: String?
    var sourceRequired: Bool
    var responsePath: [String]
    var label: String
    var contentType: String = "application/json"
    var targetEnumValues: [String] = []
}

struct TranslationResult {
    let text: String
    let endpointDescription: String
}

enum LibreTranslateError: LocalizedError {
    case invalidServerURL
    case emptyInput
    case noEndpoint
    case network(String)
    case http(Int, String)
    case badResponse(String)
    case emptyTranslation

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "翻译服务地址无效，请在设置中检查。"
        case .emptyInput:
            return "没有可翻译的文本。"
        case .noEndpoint:
            return "没有找到可用的翻译接口。请检查服务是否运行，或在高级设置中手动填写接口路径。"
        case .network(let message):
            return "无法连接到翻译服务：\(message)"
        case .http(let code, let body):
            let detail = body.isEmpty ? "" : "：\(body)"
            return "翻译服务返回错误（HTTP \(code)）\(detail)"
        case .badResponse(let body):
            let preview = body.isEmpty ? "响应为空" : String(body.prefix(180))
            return "无法解析翻译结果：\(preview)"
        case .emptyTranslation:
            return "翻译服务返回了空的译文。"
        }
    }
}
