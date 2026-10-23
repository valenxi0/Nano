import Foundation
var info: [String: String] = [:]
for arg in CommandLine.arguments.dropFirst() {
    let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 { info[parts[0]] = parts[1] }
}
DistributedNotificationCenter.default().postNotificationName(
    .init("Nano.previewNotification"), object: nil, userInfo: info, deliverImmediately: true)
