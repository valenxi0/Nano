import AppKit
import Foundation
import Security

// This helper never calls AXIsProcessTrusted: only Nano can report Nano's trust.
let applications = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "com.nanoapp.Nano"
}
guard applications.count == 1, let application = applications.first else {
    print("{\"error\":\"Expected exactly one running com.nanoapp.Nano process\"}")
    exit(2)
}
let pid = application.processIdentifier
var report: [String: Any] = [
    "pid": Int(pid),
    "runningExecutable": application.executableURL?.path ?? "",
    "bundleIdentifier": application.bundleIdentifier ?? "",
    "bundlePath": application.bundleURL?.path ?? "",
    "liveAXIsProcessTrusted": NSNull(),
    "liveAXSource": "unavailable: running build did not answer",
]

var code: SecCode?
let codeStatus = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code)
report["liveCodeLookupStatus"] = Int(codeStatus)
if codeStatus == errSecSuccess, let code {
    var staticCode: SecStaticCode?
    let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
    report["liveCodeValidityStatus"] = Int(SecCodeCheckValidity(code, [], nil))
    guard staticStatus == errSecSuccess, let staticCode else {
        print("{\"error\":\"Could not resolve the running code's static identity\"}")
        exit(2)
    }
    var information: CFDictionary?
    let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
    report["liveSigningInfoStatus"] = Int(status)
    if status == errSecSuccess, let info = information as? [String: Any] {
        report["liveSigningIdentifier"] = info[kSecCodeInfoIdentifier as String]
        report["liveTeamIdentifier"] = info[kSecCodeInfoTeamIdentifier as String] ?? NSNull()
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] {
            report["liveSigningAuthorities"] = certificates.compactMap { SecCertificateCopySubjectSummary($0) as String? }
        } else {
            report["liveSigningAuthorities"] = [String]()
        }
    }
    var requirement: SecRequirement?
    if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement {
        var requirementText: CFString?
        if SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess, let requirementText {
            report["liveDesignatedRequirement"] = requirementText as String
            report["liveRequirementContainsCDHash"] = (requirementText as String).contains("cdhash")
        }
    }
}

let request = UUID().uuidString
var received = false
let center = DistributedNotificationCenter.default()
let observer = center.addObserver(
    forName: Notification.Name("Nano.accessibilityDiagnostic.response"),
    object: request,
    queue: .main
) { notification in
    guard let info = notification.userInfo,
          let respondingPID = info["pid"] as? Int,
          respondingPID == Int(pid),
          info["executable"] as? String == application.executableURL?.path,
          info["bundleIdentifier"] as? String == application.bundleIdentifier,
          let trusted = info["accessibilityTrusted"] as? Bool
    else { return }
    report["liveAXIsProcessTrusted"] = trusted
    report["liveAXSource"] = "running Nano diagnostic response"
    report["permissions"] = info["permissions"]
    received = true
}
center.postNotificationName(
    Notification.Name("Nano.accessibilityDiagnostic.request"),
    object: request,
    userInfo: ["pid": Int(pid)],
    deliverImmediately: true
)
let deadline = Date().addingTimeInterval(3)
while !received && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
center.removeObserver(observer)
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
