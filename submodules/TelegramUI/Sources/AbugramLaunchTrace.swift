import Foundation
import UIKit

// MARK: Abugram
// On-screen launch trace. Sideloaded installs cannot be debugged with a Mac attached, so while the app starts
// it shows the launch step it has reached in a small line at the bottom of the screen. If launch ever stops on
// a blank screen, a screenshot tells exactly where. The line disappears once the first screen is up.

private final class AbugramLaunchTraceState {
    static let shared = AbugramLaunchTraceState()

    let startTime = CFAbsoluteTimeGetCurrent()
    var steps: [String] = []
    var proxyStatus = "proxy: checking"
    weak var window: UIWindow?
    var label: UILabel?
    var timer: Timer?
    var finished = false
}

private func abugramLaunchTraceText(_ state: AbugramLaunchTraceState) -> String {
    let elapsed = CFAbsoluteTimeGetCurrent() - state.startTime
    let recent = state.steps.suffix(3).joined(separator: "\n")
    return String(format: "Abugram %.1fs · %@\n%@", elapsed, state.proxyStatus, recent)
}

private func abugramLaunchTraceRefresh() {
    let state = AbugramLaunchTraceState.shared
    guard let window = state.window, let label = state.label else {
        return
    }
    label.text = abugramLaunchTraceText(state)
    let width = window.bounds.width - 16.0
    let size = label.sizeThatFits(CGSize(width: width, height: 200.0))
    label.frame = CGRect(x: 8.0, y: window.bounds.height - size.height - 40.0, width: width, height: size.height)
    window.bringSubviewToFront(label)
}

/// Starts showing the trace on `window`. Call on the main thread once the main window exists.
func abugramLaunchTraceAttach(window: UIWindow) {
    let state = AbugramLaunchTraceState.shared
    if state.finished || state.label != nil {
        return
    }
    let label = UILabel()
    label.numberOfLines = 0
    label.font = UIFont.monospacedSystemFont(ofSize: 10.0, weight: .regular)
    label.textColor = UIColor(white: 0.35, alpha: 1.0)
    label.isUserInteractionEnabled = false
    window.addSubview(label)
    state.window = window
    state.label = label
    abugramLaunchTraceRefresh()
    state.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true, block: { _ in
        abugramLaunchTraceRefresh()
    })
}

/// Records a launch step. Safe from any thread.
func abugramLaunchTrace(_ step: String) {
    let apply = {
        let state = AbugramLaunchTraceState.shared
        state.steps.append(step)
        abugramLaunchTraceRefresh()
    }
    if Thread.isMainThread {
        apply()
    } else {
        DispatchQueue.main.async(execute: apply)
    }
}

/// Records the built-in proxy outcome. Safe from any thread.
func abugramLaunchTraceProxy(_ status: String) {
    DispatchQueue.main.async {
        AbugramLaunchTraceState.shared.proxyStatus = status
        abugramLaunchTraceRefresh()
    }
}

/// Removes the trace a few seconds after the first real screen is shown.
func abugramLaunchTraceFinish() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: {
        let state = AbugramLaunchTraceState.shared
        state.finished = true
        state.timer?.invalidate()
        state.timer = nil
        state.label?.removeFromSuperview()
        state.label = nil
    })
}
