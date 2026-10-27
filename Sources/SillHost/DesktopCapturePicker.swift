// Copyright 2026 DUO你电脑 contributors. SPDX-License-Identifier: Apache-2.0
import AppKit
import ScreenCaptureKit

/// The system grants access to the returned filter, rather than to a rebuilt copy of it.
/// Keep this owner alive until the capture ends. No global recording grant is requested.
@MainActor
@available(macOS 15.2, *)
final class DesktopCapturePicker: NSObject, SCContentSharingPickerObserver {
    enum Failure: Error { case busy, unavailable, cancelled, timedOut, wrongContent }

    private var waiting: CheckedContinuation<SCContentFilter, any Error>?
    private var deadline: Task<Void, Never>?
    private var registered = false
    private var hasStarted = false

    func selectDisplay(timeout: Duration = .seconds(120)) async throws -> SCContentFilter {
        try Task.checkCancellation()
        guard !hasStarted else { throw Failure.busy }
        hasStarted = true
        let picker = SCContentSharingPicker.shared
        if #available(macOS 27, *), !picker.isAvailable { throw Failure.unavailable }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        registered = true
        picker.isActive = true

        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.fail(Failure.timedOut)
                }
                print("Desktop picker presenting at \(Date()), mainThread=\(Thread.isMainThread)")
                picker.present()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(CancellationError()) }
        }
    }

    func end() {
        fail(Failure.cancelled)
    }

    private func fail(_ error: any Error) {
        let pending = waiting
        waiting = nil
        deadline?.cancel()
        deadline = nil
        if registered {
            let picker = SCContentSharingPicker.shared
            picker.remove(self)
            picker.isActive = false
            registered = false
        }
        pending?.resume(throwing: error)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        print("Desktop picker cancelled at \(Date()), existingStream=\(stream != nil)")
        Task { @MainActor [weak self] in self?.fail(Failure.cancelled) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self, stream == nil, let pending = self.waiting else { return }
            guard filter.style == .display, filter.includedDisplays.count == 1 else {
                self.fail(Failure.wrongContent)
                return
            }
            self.waiting = nil
            self.deadline?.cancel()
            self.deadline = nil
            pending.resume(returning: filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor [weak self] in self?.fail(error) }
    }
}
