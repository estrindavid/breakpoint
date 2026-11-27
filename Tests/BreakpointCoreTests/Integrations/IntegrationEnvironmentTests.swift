import Foundation
import Testing
@testable import BreakpointCore

@Suite("Integration environment")
struct IntegrationEnvironmentTests {
    let paths = BreakpointPaths(home: URL(fileURLWithPath: "/Users/tester", isDirectory: true))

    @Test func codexHomePrecedence() {
        #expect(IntegrationEnvironment(paths: paths).codexHome.path == "/Users/tester/.codex")
        #expect(IntegrationEnvironment(paths: paths, processEnvironment: ["CODEX_HOME": "/opt/codex"]).codexHome.path == "/opt/codex")
        #expect(IntegrationEnvironment(paths: paths, codexHomeOverride: "~/alt", processEnvironment: ["CODEX_HOME": "/opt/codex"])
            .codexHome.path == "/Users/tester/alt")
    }

    @Test func everyIntegrationEditsFilesUnderTheInjectedHome() {
        for integration in IntegrationRegistry.all(environment: IntegrationEnvironment(paths: paths)) {
            #expect(integration.configFile.path.hasPrefix("/Users/tester/"), "\(integration.id)")
        }
    }
}
