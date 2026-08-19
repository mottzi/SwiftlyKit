import Testing
@testable import SwiftlyKit

@Suite("SwiftPM process environment")
struct SwiftPMEnvironmentTests {

    @Test("Plain, sensitive, empty, and unset entries resolve against one inherited snapshot")
    func resolvesEntries() throws {

        let environment = try SwiftPMEnvironment([
            "EMPTY": .plain(""),
            "PLAIN": .plain("new"),
            "REMOVE": .unset,
            "SECRET": .sensitive("private")
        ])
        let inherited = [
            "PLAIN": "old",
            "REMOVE": "inherited",
            "STABLE": "captured"
        ]

        let snapshot = environment.snapshot(inheriting: inherited)

        #expect(snapshot.values["EMPTY"] == "")
        #expect(snapshot.values["PLAIN"] == "new")
        #expect(snapshot.values["REMOVE"] == nil)
        #expect(snapshot.values["SECRET"] == "private")
        #expect(snapshot.values["STABLE"] == "captured")
        #expect(snapshot.sensitiveNames == ["SECRET"])
        #expect(snapshot.toolValues == inherited)
    }

    @Test("Known SwiftPM credentials are sensitive and do not reach selected host tools")
    func credentialsAreSensitive() throws {

        let environment = try SwiftPMEnvironment([
            "SWIFTPM_REGISTRY_PASSWORD": .plain("password"),
            "SWIFTPM_SOURCE_CONTROL_TOKEN": .sensitive("token")
        ])
        let snapshot = environment.snapshot(inheriting: [
            "SWIFTPM_NETRC_DATA": "machine example.com",
            "SWIFTPM_REGISTRY_LOGIN": "builder"
        ])

        #expect(snapshot.sensitiveNames == [
            "SWIFTPM_NETRC_DATA",
            "SWIFTPM_REGISTRY_LOGIN",
            "SWIFTPM_REGISTRY_PASSWORD",
            "SWIFTPM_SOURCE_CONTROL_TOKEN"
        ])
        #expect(snapshot.toolValues.isEmpty)
    }

    @Test("Inherited compiler and SDK overrides are removed")
    func inheritedOverridesAreRemoved() {

        let removedNames = [
            "ADDITIONAL_SWIFT_DRIVER_FLAGS", "AR", "CC", "CLANG_PATH", "CXX", "LD", "LIBTOOL", "SDKROOT",
            "SDK_ROOT", "SWIFT_DRIVER_CLANG_EXEC", "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC",
            "SWIFTPM_CUSTOM_BINDIR", "SWIFTPM_CUSTOM_BIN_DIR", "SWIFTPM_CUSTOM_LIBS_DIR",
            "SWIFTPM_PD_LIBS", "SWIFT_EXEC", "SWIFT_EXEC_MANIFEST", "TOOLCHAINS", "TOOLCHAIN_PATH"
        ]
        var inherited = Dictionary(uniqueKeysWithValues: removedNames.map { ($0, "/tmp/override") })
        inherited["STABLE"] = "value"

        let snapshot = SwiftPMEnvironment.inherited.snapshot(inheriting: inherited)

        #expect(snapshot.values == ["STABLE": "value"])
        #expect(snapshot.toolValues == ["STABLE": "value"])
    }

    @Test(
        "Protected process values are rejected",
        arguments: [
            "CFFIXED_USER_HOME",
            "ADDITIONAL_SWIFT_DRIVER_FLAGS",
            "DEVELOPER_DIR",
            "HOME",
            "PATH",
            "SWIFTLY_HOME",
            "SWIFTLY_HOME_DIR",
            "SDKROOT",
            "SWIFTLY_BIN_DIR",
            "SWIFTLY_TOOLCHAINS_DIR",
            "SWIFT_EXEC",
            "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC",
            "TOOLCHAIN_PATH"
        ]
    )
    func rejectsProtectedName(_ name: String) {

        #expect(throws: SwiftlyKitError.invalidSwiftPMEnvironmentVariable(name)) {
            try SwiftPMEnvironment([name: .plain("value")])
        }
    }

    @Test("Invalid names and NUL values are rejected without reporting the value")
    func rejectsInvalidInput() {

        #expect(throws: SwiftlyKitError.invalidSwiftPMEnvironmentVariable("NOT-VALID")) {
            try SwiftPMEnvironment(["NOT-VALID": .plain("value")])
        }
        #expect(throws: SwiftlyKitError.invalidSwiftPMEnvironmentVariable("VALID")) {
            try SwiftPMEnvironment(["VALID": .sensitive("private\0value")])
        }

        let description = SwiftlyKitError.invalidSwiftPMEnvironmentVariable("VALID").errorDescription
        #expect(description?.contains("private") == false)
    }

}
