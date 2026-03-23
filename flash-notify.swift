#!/usr/bin/env swift
import Foundation

guard CommandLine.arguments.count >= 2 else { exit(1) }
let event = CommandLine.arguments[1] // "on" or "off"

let data = FileHandle.standardInput.readDataToEndOfFile()
let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
let sessionId = json?["session_id"] as? String ?? "unknown"

// Find repo root by traversing up looking for .jj directory
let cwd = json?["cwd"] as? String ?? ""
var dir = cwd
while !dir.isEmpty && dir != "/" {
    if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".jj")) {
        break
    }
    dir = (dir as NSString).deletingLastPathComponent
}
let repoRoot = (!dir.isEmpty && dir != "/") ? dir : cwd
let displayName = (repoRoot as NSString).lastPathComponent

let payload: [String: String] = ["id": sessionId, "name": displayName]
let payloadData = try! JSONSerialization.data(withJSONObject: payload)
let payloadString = String(data: payloadData, encoding: .utf8)!

let name = "com.vibelimit.flash.\(event)"
DistributedNotificationCenter.default().postNotificationName(
    NSNotification.Name(name), object: payloadString)
