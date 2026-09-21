// Tests/MeridianCompanionAppTests/MeridianCompanionAppShellTests.swift
import XCTest
@testable import MeridianCompanionApp

/// Confirms the target builds and links against `ProjectModel`/`AudioEngine`.
/// Real tests arrive once this app has an approved milestone spec/plan —
/// see docs/superpowers/specs/2026-09-20-two-app-architecture-design.md.
final class MeridianCompanionAppShellTests: XCTestCase {
    func testContentViewBuilds() {
        _ = ContentView()
    }
}
