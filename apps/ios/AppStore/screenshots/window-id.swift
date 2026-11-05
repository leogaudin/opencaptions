import CoreGraphics
// The number of the largest window a process has on screen, which is what `screencapture -l` takes.
// usage: window-id <pid>
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let area: ([String: Any]) -> Double = { window in
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}
if let largest = windows.filter({ $0[kCGWindowOwnerPID as String] as? Int == pid }).max(by: { area($0) < area($1) }),
    let number = largest[kCGWindowNumber as String] as? Int
{
    print(number)
}
