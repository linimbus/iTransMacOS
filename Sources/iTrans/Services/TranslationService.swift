import Foundation

/// Translates text using the configured backend.
///
/// The service discovers its endpoint either from an OpenAPI 3 document
/// (`/openapi.json`), a Swagger 2.0 document (`/spec`, Flasgger/FastAPI), or
/// falls back to well-known LibreTranslate style defaults.
@MainActor
final class TranslationService {
    private var cachedConfigurations: [APIConfiguration] = []
    private var cachedBase: String = ""
    private var cachedDate: Date = .distantPast

    private let cacheLifetime: TimeInterval = 60 * 5

    private let documentPaths = [
        "/openapi.json",
        "/spec",
        "/api/openapi.json",
        "/apispec_1.json",
        "/swagger.json"
    ]

    func translate(text: String, settings: AppSettings) async throws -> TranslationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibreTranslateError.emptyInput }
        guard let base = settings.serverBaseURL else { throw LibreTranslateError.invalidServerURL }

        let configurations = await configurations(base: base, settings: settings)
        guard !configurations.isEmpty else { throw LibreTranslateError.noEndpoint }

        var lastError: Error = LibreTranslateError.noEndpoint

        // Prefer endpoints that are explicitly named as translation endpoints so
        // that we never fall back to unrelated utilities such as /detect.
        let preferred = configurations.filter { $0.path.lowercased().contains("translat") }
        let candidates = preferred.isEmpty ? configurations : preferred

        for configuration in candidates.prefix(6) {
            do {
                return try await perform(configuration, text: trimmed, settings: settings)
            } catch {
                lastError = error
                if case LibreTranslateError.network = error { break }
                if case LibreTranslateError.http(let code, _) = error,
                   code == 400 || code == 401 || code == 403 || code == 422 {
                    break
                }
            }
        }

        throw lastError
    }

    // MARK: - Configuration resolution

    private func configurations(base: URL, settings: AppSettings) async -> [APIConfiguration] {
        if let manual = settings.manualAPIConfiguration {
            return [manual]
        }

        let key = base.absoluteString
        if cachedBase == key,
           !cachedConfigurations.isEmpty,
           Date().timeIntervalSince(cachedDate) < cacheLifetime {
            return cachedConfigurations
        }

        if let discovered = try? await discover(base: base), !discovered.isEmpty {
            cachedConfigurations = discovered
            cachedBase = key
            cachedDate = Date()
            return discovered
        }

        return fallbackConfigurations(base: base)
    }

    private func fallbackConfigurations(base: URL) -> [APIConfiguration] {
        let libretranslate = APIConfiguration(
            baseURL: base,
            path: "/translate",
            method: "POST",
            textField: "q",
            targetField: "target",
            sourceField: "source",
            sourceRequired: true,
            responsePath: ["translatedText"],
            label: "POST /translate（LibreTranslate 兼容）",
            contentType: "application/x-www-form-urlencoded"
        )

        let generic = APIConfiguration(
            baseURL: base,
            path: "/translate",
            method: "POST",
            textField: "text",
            targetField: "target_lang",
            sourceField: nil,
            sourceRequired: false,
            responsePath: [],
            label: "POST /translate（默认推断）"
        )

        return [libretranslate, generic]
    }

    // MARK: - Request execution

    private func perform(
        _ configuration: APIConfiguration,
        text: String,
        settings: AppSettings
    ) async throws -> TranslationResult {
        guard let url = makeURL(base: configuration.baseURL, path: configuration.path) else {
            throw LibreTranslateError.invalidServerURL
        }

        var payload: [String: Any] = [configuration.textField: text]
        if let targetField = configuration.targetField {
            let desired = settings.effectiveTargetValue
            payload[targetField] = pickEnumValue(
                desired: desired,
                candidates: configuration.targetEnumValues,
                languageID: settings.targetLanguageID
            ) ?? desired
        }
        if let sourceField = configuration.sourceField {
            if let sourceValue = settings.effectiveSourceValue {
                payload[sourceField] = sourceValue
            } else if configuration.sourceRequired {
                payload[sourceField] = "auto"
            }
        }

        var request: URLRequest
        if configuration.method == "GET" {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw LibreTranslateError.invalidServerURL
            }
            components.queryItems = payload.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
            guard let finalURL = components.url else { throw LibreTranslateError.invalidServerURL }
            request = URLRequest(url: finalURL)
        } else {
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            if configuration.contentType == "application/x-www-form-urlencoded" {
                var components = URLComponents()
                components.queryItems = payload.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
            } else {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            }
        }
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LibreTranslateError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LibreTranslateError.badResponse("无效的服务响应")
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LibreTranslateError.http(http.statusCode, String(body.prefix(300)))
        }

        guard let translated = extractTranslation(from: data, path: configuration.responsePath),
              !translated.isEmpty else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LibreTranslateError.badResponse(body)
        }

        return TranslationResult(
            text: translated,
            endpointDescription: configuration.label
        )
    }

    private func makeURL(base: URL, path: String) -> URL? {
        var baseString = base.absoluteString
        while baseString.hasSuffix("/") { baseString.removeLast() }
        var suffix = path
        if !suffix.hasPrefix("/") { suffix = "/" + suffix }
        return URL(string: baseString + suffix)
    }

    // MARK: - API document discovery

    private struct Candidate {
        let configuration: APIConfiguration
        let score: Int
    }

    func discover(base: URL) async throws -> [APIConfiguration] {
        var lastError: Error = LibreTranslateError.noEndpoint

        for documentPath in documentPaths {
            do {
                let configurations = try await discover(base: base, documentPath: documentPath)
                if !configurations.isEmpty {
                    return configurations
                }
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func discover(base: URL, documentPath: String) async throws -> [APIConfiguration] {
        guard let url = makeURL(base: base, path: documentPath) else {
            throw LibreTranslateError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LibreTranslateError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LibreTranslateError.badResponse("无法读取 \(documentPath)")
        }

        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = document["paths"] as? [String: Any] else {
            throw LibreTranslateError.badResponse("\(documentPath) 格式无效")
        }

        let basePath = documentBasePath(document)
        var candidates: [Candidate] = []

        for (rawPath, pathValue) in paths {
            guard let pathItem = pathValue as? [String: Any] else { continue }
            let path = joinBasePath(basePath, rawPath)

            for method in ["post", "get"] {
                guard let operation = pathItem[method] as? [String: Any] else { continue }
                if let candidate = makeCandidate(
                    base: base,
                    path: path,
                    rawPath: rawPath,
                    method: method,
                    operation: operation,
                    document: document
                ) {
                    candidates.append(candidate)
                }
            }
        }

        let sorted = candidates.sorted { $0.score > $1.score }
        var seen: Set<String> = []
        var result: [APIConfiguration] = []
        for candidate in sorted {
            let key = "\(candidate.configuration.method) \(candidate.configuration.path)"
            if seen.insert(key).inserted {
                result.append(candidate.configuration)
            }
        }
        return result
    }

    private func documentBasePath(_ document: [String: Any]) -> String {
        if let basePath = document["basePath"] as? String,
           !basePath.isEmpty,
           basePath != "/" {
            return basePath
        }
        if let servers = document["servers"] as? [[String: Any]],
           let serverURL = servers.first?["url"] as? String,
           let url = URL(string: serverURL),
           !url.path.isEmpty,
           url.path != "/" {
            return url.path
        }
        return ""
    }

    private func joinBasePath(_ basePath: String, _ path: String) -> String {
        guard !basePath.isEmpty else { return path }
        var prefix = basePath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        var suffix = path
        if !suffix.hasPrefix("/") { suffix = "/" + suffix }
        return prefix + suffix
    }

    private func makeCandidate(
        base: URL,
        path: String,
        rawPath: String,
        method: String,
        operation: [String: Any],
        document: [String: Any]
    ) -> Candidate? {
        let pathLower = rawPath.lowercased()
        let operationID = operation["operationId"] as? String ?? ""
        let summary = operation["summary"] as? String ?? ""
        let description = operation["description"] as? String ?? ""
        let tags = (operation["tags"] as? [String])?.joined(separator: " ") ?? ""
        let text = [pathLower, operationID, summary, description, tags]
            .joined(separator: " ")
            .lowercased()

        var score = 0
        if pathLower.contains("translat") { score += 30 }
        if text.contains("translat") || text.contains("翻译") { score += 20 }
        if pathLower.contains("image") || pathLower.contains("upload") { score -= 80 }
        if pathLower.contains("batch") { score -= 10 }

        let (bodySchema, bodyContentType) = requestSchema(for: operation, document: document)
        var requestProperties = properties(of: bodySchema)
        var requiredNames = Set((bodySchema["required"] as? [String] ?? []).map { $0.lowercased() })
        var contentType = bodyContentType
        var hasFormData = false

        // Swagger 2.0 and GET style APIs describe fields as parameters.
        if let parameters = operation["parameters"] as? [[String: Any]] {
            for parameter in parameters {
                guard let location = parameter["in"] as? String,
                      location == "formData" || location == "query",
                      let name = parameter["name"] as? String else { continue }

                let schemaAny = parameter["schema"] ?? ["type": parameter["type"] as? String ?? "string"]
                let schema = resolve(schemaAny, document: document)
                requestProperties[name] = schema.isEmpty ? ["type": "string"] : schema
                if (parameter["required"] as? Bool) == true {
                    requiredNames.insert(name.lowercased())
                }
                if location == "formData" { hasFormData = true }
            }
        }

        if hasFormData {
            contentType = "application/x-www-form-urlencoded"
        }

        let requestKeys = Set(requestProperties.keys.map { $0.lowercased() })
        if requestKeys.contains("file") || requestKeys.contains("image") || requestKeys.contains("upload") {
            return nil
        }

        let textField = pickField(
            ["text", "q", "query", "content", "source_text", "sourcetext", "input", "original"],
            in: requestProperties
        )
        let targetField = pickField(
            ["target_lang", "targetlang", "target_language", "targetlanguage", "target", "to", "dst", "lang_to"],
            in: requestProperties
        )
        let sourceField = pickField(
            ["source_lang", "sourcelang", "source_language", "sourcelanguage", "source", "from", "src", "lang_from"],
            in: requestProperties
        )

        guard let textField else { return nil }
        score += 10
        if targetField != nil { score += 5 }
        if method == "post" { score += 5 }

        guard score > 0 else { return nil }

        let sourceRequired = sourceField.map { requiredNames.contains($0.lowercased()) } ?? false
        let responsePath = responseTextPath(for: operation, document: document) ?? []
        let label = "\(method.uppercased()) \(path)"

        let targetEnumValues: [String] = {
            guard let targetField, let rawSchema = requestProperties[targetField] else { return [] }
            let schema = resolve(rawSchema, document: document)
            return (schema["enum"] as? [Any])?.compactMap { $0 as? String } ?? []
        }()

        let configuration = APIConfiguration(
            baseURL: base,
            path: path,
            method: method.uppercased(),
            textField: textField,
            targetField: targetField,
            sourceField: sourceField,
            sourceRequired: sourceRequired,
            responsePath: responsePath,
            label: label,
            contentType: contentType,
            targetEnumValues: targetEnumValues
        )
        return Candidate(configuration: configuration, score: score)
    }

    private func requestSchema(
        for operation: [String: Any],
        document: [String: Any]
    ) -> ([String: Any], String) {
        if let requestBody = operation["requestBody"] as? [String: Any],
           let content = requestBody["content"] as? [String: Any] {
            if let media = content["application/json"] as? [String: Any], let schema = media["schema"] {
                return (resolve(schema, document: document), "application/json")
            }
            if let media = content["application/x-www-form-urlencoded"] as? [String: Any],
               let schema = media["schema"] {
                return (resolve(schema, document: document), "application/x-www-form-urlencoded")
            }
        }

        if let consumes = operation["consumes"] as? [String],
           consumes.contains("application/x-www-form-urlencoded") {
            return ([:], "application/x-www-form-urlencoded")
        }

        return ([:], "application/json")
    }

    private func properties(of schema: [String: Any]) -> [String: Any] {
        schema["properties"] as? [String: Any] ?? [:]
    }

    private func resolve(_ schemaAny: Any, document: [String: Any], depth: Int = 0) -> [String: Any] {
        guard depth < 8, let schema = schemaAny as? [String: Any] else { return [:] }

        if let ref = schema["$ref"] as? String, let target = value(forReference: ref, in: document) {
            return resolve(target, document: document, depth: depth + 1)
        }

        if let allOf = schema["allOf"] as? [Any] {
            var merged: [String: Any] = [:]
            for item in allOf {
                merged.merge(resolve(item, document: document, depth: depth + 1)) { _, new in new }
            }
            if let properties = schema["properties"] as? [String: Any] {
                var mergedProperties = merged["properties"] as? [String: Any] ?? [:]
                mergedProperties.merge(properties) { _, new in new }
                merged["properties"] = mergedProperties
            }
            return merged
        }

        return schema
    }

    private func value(forReference ref: String, in document: [String: Any]) -> Any? {
        guard ref.hasPrefix("#/") else { return nil }
        let parts = ref.dropFirst(2).split(separator: "/").map(String.init)
        var current: Any = document
        for part in parts {
            let key = part
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    private func pickField(_ names: [String], in properties: [String: Any]) -> String? {
        for name in names {
            if let actual = properties.keys.first(where: { $0.lowercased() == name.lowercased() }) {
                return actual
            }
        }
        return nil
    }

    private func responseTextPath(for operation: [String: Any], document: [String: Any]) -> [String]? {
        guard let responses = operation["responses"] as? [String: Any],
              let ok = responses["200"] as? [String: Any] ?? responses["201"] as? [String: Any] else {
            return nil
        }

        var schema: Any?
        if let content = ok["content"] as? [String: Any] {
            if let media = content["application/json"] as? [String: Any] {
                schema = media["schema"]
            } else if let media = content.values.first as? [String: Any] {
                schema = media["schema"]
            }
        } else {
            // Swagger 2.0
            schema = ok["schema"]
        }

        guard let schema else { return nil }

        let resolved = resolve(schema, document: document)
        if resolved["type"] as? String == "string" {
            return []
        }

        return findTextPath(in: schema, document: document, prefix: [], depth: 0)
    }

    private func findTextPath(
        in schemaAny: Any,
        document: [String: Any],
        prefix: [String],
        depth: Int
    ) -> [String]? {
        guard depth < 4 else { return nil }
        let schema = resolve(schemaAny, document: document)
        guard !schema.isEmpty else { return nil }

        if schema["type"] as? String == "string" {
            return prefix
        }

        if schema["type"] as? String == "array", let items = schema["items"] {
            let resolvedItems = resolve(items, document: document)
            if resolvedItems["type"] as? String == "string" {
                return prefix + ["0"]
            }
        }

        if let oneOf = schema["oneOf"] as? [Any] {
            for variant in oneOf {
                if let path = findTextPath(in: variant, document: document, prefix: prefix, depth: depth + 1) {
                    return path
                }
            }
        }

        guard let properties = schema["properties"] as? [String: Any] else { return nil }
        let preferred = [
            "translated_text", "translatedtext", "translation", "translated",
            "result", "text", "output", "content", "data"
        ]

        for key in preferred {
            guard let match = properties.first(where: { $0.key.lowercased() == key }) else { continue }
            if let path = findTextPath(
                in: match.value,
                document: document,
                prefix: prefix + [match.key],
                depth: depth + 1
            ) {
                return path
            }
        }

        for (key, child) in properties {
            if preferred.contains(key.lowercased()) { continue }
            if let path = findTextPath(in: child, document: document, prefix: prefix + [key], depth: depth + 1) {
                return path
            }
        }

        return nil
    }

    // MARK: - Response parsing

    private func extractTranslation(from data: Data, path: [String]) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let value = navigate(object, path: path) {
                if let text = stringValue(value) {
                    return text
                }
            }
            if let found = deepSearch(object) {
                return found
            }
            return nil
        }

        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func navigate(_ object: Any, path: [String]) -> Any? {
        var current: Any = object
        for key in path {
            if let dictionary = current as? [String: Any], let next = dictionary[key] {
                current = next
            } else if let array = current as? [Any], let index = Int(key), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    private func stringValue(_ value: Any) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { stringValue($0) }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return nil
    }

    private func deepSearch(_ value: Any, depth: Int = 0) -> String? {
        guard depth < 6 else { return nil }

        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let array = value as? [Any] {
            for element in array {
                if let found = deepSearch(element, depth: depth + 1) { return found }
            }
            return nil
        }

        if let dictionary = value as? [String: Any] {
            let keys = [
                "translated_text", "translatedtext", "translation", "translated",
                "result", "target_text", "text", "output", "content", "data", "message"
            ]
            for key in keys {
                if let child = dictionary.first(where: { $0.key.lowercased() == key })?.value,
                   let found = deepSearch(child, depth: depth + 1) {
                    return found
                }
            }
            for (key, child) in dictionary {
                if keys.contains(key.lowercased()) { continue }
                if let found = deepSearch(child, depth: depth + 1) {
                    return found
                }
            }
        }

        return nil
    }

    // MARK: - Enum matching

    private func pickEnumValue(desired: String, candidates: [String], languageID: String) -> String? {
        guard !candidates.isEmpty else { return nil }

        if let exact = candidates.first(where: { $0.caseInsensitiveCompare(desired) == .orderedSame }) {
            return exact
        }

        for alias in enumAliases(for: languageID, desired: desired) {
            if let match = candidates.first(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) {
                return match
            }
        }
        return nil
    }

    private func enumAliases(for languageID: String, desired: String) -> [String] {
        switch languageID {
        case "zh":
            return [desired, "zh", "zh-CN", "zh-Hans", "zh_CN", "chinese", "chinese (simplified)", "simp", "中文", "简体中文", "汉语"]
        case "zh-TW":
            return [desired, "zh-TW", "zh-Hant", "zh_TW", "chinese (traditional)", "trad", "繁體中文", "繁体中文"]
        case "en":
            return [desired, "en", "en-US", "english", "英文", "英语"]
        case "ja":
            return [desired, "ja", "ja-JP", "japanese", "日本語", "日语"]
        case "ko":
            return [desired, "ko", "ko-KR", "korean", "한국어", "韩语"]
        case "fr":
            return [desired, "fr", "fr-FR", "french", "français", "法语"]
        case "de":
            return [desired, "de", "de-DE", "german", "deutsch", "德语"]
        case "es":
            return [desired, "es", "es-ES", "spanish", "español", "西班牙语"]
        case "ru":
            return [desired, "ru", "ru-RU", "russian", "русский", "俄语"]
        case "pt":
            return [desired, "pt", "pt-BR", "portuguese", "português", "葡萄牙语"]
        case "it":
            return [desired, "it", "it-IT", "italian", "italiano", "意大利语"]
        default:
            return [desired]
        }
    }
}
