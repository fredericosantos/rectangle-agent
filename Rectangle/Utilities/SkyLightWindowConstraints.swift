/// SkyLightWindowConstraints.swift
//
/// Reads a window's minimum and maximum size from the WindowServer.
///
/// Private and undocumented, so every entry point degrades to nil rather than assuming success.
/// Signature recovered by disassembling `SLSWindowIteratorGetConstraints`, which copies three
/// 16-byte values out of the iterator: minimum size, maximum size, and current size. A `csel` on
/// a field inside the iterator can shift the output registers by one, so a fourth pointer is
/// passed to keep that branch writing somewhere valid.

import Foundation

private enum SkyLightWindowConstraints {

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias QueryWindows = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<AnyObject>?
    private typealias CopyWindows = @convention(c) (AnyObject) -> Unmanaged<AnyObject>?
    private typealias Advance = @convention(c) (AnyObject) -> Bool
    private typealias GetWindowID = @convention(c) (AnyObject) -> UInt32
    private typealias GetConstraints = @convention(c) (AnyObject,
                                                      UnsafeMutablePointer<CGSize>,
                                                      UnsafeMutablePointer<CGSize>,
                                                      UnsafeMutablePointer<CGSize>,
                                                      UnsafeMutablePointer<CGSize>) -> Void

    private struct Entry {
        let connection: Int32
        let queryWindows: QueryWindows
        let copyWindows: CopyWindows
        let advance: Advance
        let windowID: GetWindowID
        let constraints: GetConstraints
    }

    private static let entry: Entry? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connectionSymbol = dlsym(handle, "SLSMainConnectionID"),
              let querySymbol = dlsym(handle, "SLSWindowQueryWindows"),
              let copySymbol = dlsym(handle, "SLSWindowQueryResultCopyWindows"),
              let advanceSymbol = dlsym(handle, "SLSWindowIteratorAdvance"),
              let windowIDSymbol = dlsym(handle, "SLSWindowIteratorGetWindowID"),
              let constraintsSymbol = dlsym(handle, "SLSWindowIteratorGetConstraints")
        else { return nil }

        return Entry(connection: unsafeBitCast(connectionSymbol, to: MainConnectionID.self)(),
                     queryWindows: unsafeBitCast(querySymbol, to: QueryWindows.self),
                     copyWindows: unsafeBitCast(copySymbol, to: CopyWindows.self),
                     advance: unsafeBitCast(advanceSymbol, to: Advance.self),
                     windowID: unsafeBitCast(windowIDSymbol, to: GetWindowID.self),
                     constraints: unsafeBitCast(constraintsSymbol, to: GetConstraints.self))
    }()

    /// - Returns: the three sizes the routine reports, or nil if it could not be asked. `current`
    ///   is the caller's only check that the output slots are in the order assumed here — see
    ///   `achievableSize(for:)`.
    static func read(_ windowId: CGWindowID) -> (min: CGSize, max: CGSize, current: CGSize)? {
        guard let entry else { return nil }

        let ids = [NSNumber(value: windowId)] as CFArray
        guard let query = entry.queryWindows(entry.connection, ids, 1)?.takeRetainedValue(),
              let iterator = entry.copyWindows(query)?.takeRetainedValue() else { return nil }

        while entry.advance(iterator) {
            guard entry.windowID(iterator) == windowId else { continue }

            var minimum = CGSize.zero, maximum = CGSize.zero, current = CGSize.zero, spare = CGSize.zero
            entry.constraints(iterator, &minimum, &maximum, &current, &spare)

            /// A window reporting no usable bounds tells us nothing; treat it as unknown rather
            /// than clamping everything to zero. Every slot reads zero for the first seconds of a
            /// window's life, before the app has published anything.
            guard maximum.width > 0, maximum.height > 0 else { return nil }

            /// A minimum above the maximum is not a constraint pair, it is evidence the slots do
            /// not mean what we think they mean. Clamping to it would pin the window to the
            /// maximum on both ends.
            guard minimum.width <= maximum.width, minimum.height <= maximum.height else { return nil }

            return (minimum, maximum, current)
        }

        return nil
    }
}

extension AccessibilityElement {

    /// The size this window would actually adopt if asked for `requestedSize`.
    ///
    /// The Accessibility API cannot answer this: `kAXSizeAttribute` is settable or it isn't, there
    /// is no per-axis flag and no minimum or maximum. The WindowServer does know — it is what
    /// Apple's own tiling consults — and unlike window *writes*, which it accepts and silently
    /// ignores for another process's window, constraint *reads* are honoured cross-process.
    ///
    /// Returns nil if the query fails, leaving callers on their previous assumption.
    ///
    /// The routine is private and the `csel` in it can shift which output slot holds what, so the
    /// slot order is assumed, not guaranteed. The third slot is the window's *current* size, which
    /// we already know independently — so it doubles as a checksum on the whole layout. If it does
    /// not match the live frame, the order is not (min, max, current, spare) on this OS and every
    /// other slot is suspect too: fail closed rather than clamp the window to a wrong but
    /// plausible size. Verified on macOS 27, where it matched on 7 of 7 windows.
    func achievableSize(for requestedSize: CGSize) -> CGSize? {
        guard let windowId = getWindowId(),
              let currentSize = size,
              let constraints = SkyLightWindowConstraints.read(windowId),
              abs(constraints.current.width - currentSize.width) <= 1,
              abs(constraints.current.height - currentSize.height) <= 1
        else { return nil }

        return CGSize(width: min(max(requestedSize.width, constraints.min.width), constraints.max.width),
                      height: min(max(requestedSize.height, constraints.min.height), constraints.max.height))
    }
}
