#!/usr/bin/env swift
import Foundation

guard CommandLine.arguments.count >= 2 else { exit(1) }
let event = CommandLine.arguments[1] // "on" or "off"

let data = FileHandle.standardInput.readDataToEndOfFile()
let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
let sessionId = json?["session_id"] as? String ?? "unknown"

// Build a JSON object string to pass session_id + display name
let cwd = json?["cwd"] as? String ?? ""
let displayName = (cwd as NSString).lastPathComponent

let payload: [String: String] = ["id": sessionId, "name": displayName]
let payloadData = try! JSONSerialization.data(withJSONObject: payload)
let payloadString = String(data: payloadData, encoding: .utf8)!

let name = "com.vibelimit.flash.\(event)"
DistributedNotificationCenter.default().postNotificationName(
    NSNotification.Name(name), object: payloadString)
