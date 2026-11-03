#!/usr/bin/env swift
// Create, update and end a Morph activity with URLSession.
// Usage: MORPH_TOKEN=... [MORPH_PORT=47800] swift activity.swift
import Foundation

let environment = ProcessInfo.processInfo.environment
let port = environment["MORPH_PORT"] ?? "47800"
guard let token = environment["MORPH_TOKEN"] else { fatalError("Set MORPH_TOKEN") }

@discardableResult
func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Int {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1\(path)")!)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
    let (_, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status < 400 else { fatalError("\(method) \(path) returned \(status)") }
    return status
}

try await call("POST", "/activities", ["id": "swift-001", "title": "Compilando", "icon": "build", "progress": 0.2])
try await call("PATCH", "/activities/swift-001", ["progress": 0.8])
try await call("PATCH", "/activities/swift-001", ["state": "success"])
try await call("DELETE", "/activities/swift-001")
print("done")
