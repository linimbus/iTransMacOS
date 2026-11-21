import AppKit
import os

enum AppLog {
    static let app = Logger(subsystem: "com.linimbus.itrans", category: "app")
    static let popup = Logger(subsystem: "com.linimbus.itrans", category: "popup")
    static let capture = Logger(subsystem: "com.linimbus.itrans", category: "capture")
    static let translate = Logger(subsystem: "com.linimbus.itrans", category: "translate")
}
