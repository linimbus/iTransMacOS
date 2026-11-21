#!/usr/bin/env python3
"""Local mock translation backend for developing iTrans without the real server.

Implements a small Swagger 2.0 document on /spec plus a LibreTranslate-like
/translate endpoint, so the app's automatic API discovery can be exercised.

Usage:
    python3 scripts/mock_server.py [port]
    ITRANS_SERVER=http://127.0.0.1:5017 ITRANS_DEMO_AUTO=1 \
        ./build/iTrans.app/Contents/MacOS/iTrans --demo
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SPEC = {
    "swagger": "2.0",
    "info": {"title": "Mock Translator", "version": "1.0.0"},
    "basePath": "/",
    "paths": {
        "/translate": {
            "post": {
                "summary": "Translate Text",
                "tags": ["translate"],
                "parameters": [
                    {
                        "in": "formData",
                        "name": "q",
                        "required": True,
                        "description": "Text to translate",
                        "schema": {"type": "string"},
                    },
                    {
                        "in": "formData",
                        "name": "source",
                        "required": True,
                        "description": "Source language code or auto",
                        "schema": {"type": "string"},
                    },
                    {
                        "in": "formData",
                        "name": "target",
                        "required": True,
                        "description": "Target language code",
                        "schema": {"type": "string"},
                    },
                ],
                "responses": {
                    "200": {
                        "description": "Translation",
                        "schema": {"$ref": "#/definitions/translate"},
                    }
                },
            }
        }
    },
    "definitions": {
        "translate": {
            "type": "object",
            "required": ["translatedText"],
            "properties": {
                "translatedText": {"type": "string"},
                "detectedLanguage": {
                    "type": "object",
                    "properties": {
                        "language": {"type": "string"},
                        "confidence": {"type": "number"},
                    },
                },
            },
        }
    },
}

TRANSLATIONS = {
    "Hello": "你好",
    "The quick brown fox jumps over the lazy dog. This is a demo text for the iTrans floating panel.":
        "敏捷的棕色狐狸跳过了懒狗。这是 iTrans 悬浮面板的演示文本。",
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("[mock]", fmt % args, flush=True)

    def _send(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/spec", "/openapi.json"):
            self._send(200, SPEC)
        else:
            self._send(404, {"error": "Not Found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/translate":
            self._send(404, {"error": "Not Found"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8", errors="replace")

        content_type = self.headers.get("Content-Type", "")
        if "application/json" in content_type:
            try:
                payload = json.loads(raw or "{}")
            except json.JSONDecodeError:
                self._send(400, {"error": "Invalid JSON"})
                return
            text = payload.get("q") or payload.get("text") or ""
            target = payload.get("target") or payload.get("target_lang") or "zh-Hans"
        else:
            from urllib.parse import parse_qs
            payload = {key: values[0] for key, values in parse_qs(raw).items()}
            text = payload.get("q", "")
            target = payload.get("target", "zh-Hans")

        translated = TRANSLATIONS.get(text, "【模拟译文】" + text)
        self._send(200, {
            "translatedText": translated,
            "detectedLanguage": {"language": "en", "confidence": 100.0},
            "target": target,
        })


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5017
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"mock translator on http://127.0.0.1:{port}", flush=True)
    server.serve_forever()
