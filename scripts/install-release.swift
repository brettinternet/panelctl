#!/usr/bin/env swift

import Foundation

enum InstallError: LocalizedError {
    case usage
    case invalidSource(String)
    case invalidDestination(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: install-release.swift SOURCE_APP DESTINATION_APP"
        case .invalidSource(let path):
            return "source app bundle not found: \(path)"
        case .invalidDestination(let path):
            return "destination must be an absolute .app path: \(path)"
        }
    }
}

func install(sourcePath: String, destinationPath: String) throws {
    let fileManager = FileManager.default
    let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
    let destination = URL(fileURLWithPath: destinationPath).standardizedFileURL

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
          isDirectory.boolValue,
          source.pathExtension == "app" else {
        throw InstallError.invalidSource(source.path)
    }
    guard destinationPath.hasPrefix("/"), destination.pathExtension == "app" else {
        throw InstallError.invalidDestination(destination.path)
    }

    let staging = destination
        .deletingLastPathComponent()
        .appendingPathComponent(".\(destination.lastPathComponent).installing-\(UUID().uuidString)")
    var trashedDestination: NSURL?

    defer {
        if fileManager.fileExists(atPath: staging.path) {
            try? fileManager.removeItem(at: staging)
        }
    }

    try fileManager.copyItem(at: source, to: staging)

    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.trashItem(at: destination, resultingItemURL: &trashedDestination)
    }

    do {
        try fileManager.moveItem(at: staging, to: destination)
    } catch {
        if let trashedDestination = trashedDestination as URL?,
           !fileManager.fileExists(atPath: destination.path) {
            try? fileManager.moveItem(at: trashedDestination, to: destination)
        }
        throw error
    }
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw InstallError.usage
    }
    try install(sourcePath: CommandLine.arguments[1], destinationPath: CommandLine.arguments[2])
} catch {
    FileHandle.standardError.write(Data("install failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
