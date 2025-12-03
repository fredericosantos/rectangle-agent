//
//  AnimatedWindowMover.swift
//  Rectangle
//
//  Created for window animation feature
//

import Foundation

class AnimatedWindowMover: WindowMover {
    
    private static let defaultFrameRate: TimeInterval = 1.0 / 60.0 // 60 FPS
    private static var animationIds: [ObjectIdentifier: UUID] = [:]
    private static let animationLock = NSLock()
    
    func moveWindowRect(_ windowRect: CGRect, frameOfScreen: CGRect, visibleFrameOfScreen: CGRect, frontmostWindowElement: AccessibilityElement?, action: WindowAction?) {
        guard let windowElement = frontmostWindowElement,
              let startRect = Optional(windowElement.frame),
              !startRect.isNull else {
            return
        }
        
        let duration = TimeInterval(Defaults.windowAnimationDuration.value)
        let targetRect = windowRect
        
        // If window is already at target, skip animation
        if startRect.equalTo(targetRect) {
            return
        }
        
        // Generate unique animation ID for this window
        let animationId = UUID()
        let windowKey = ObjectIdentifier(windowElement)
        
        AnimatedWindowMover.animationLock.lock()
        AnimatedWindowMover.animationIds[windowKey] = animationId
        AnimatedWindowMover.animationLock.unlock()
        
        animate(windowElement: windowElement, windowKey: windowKey, from: startRect, to: targetRect, duration: duration, animationId: animationId)
    }
    
    private func isAnimationValid(windowKey: ObjectIdentifier, animationId: UUID) -> Bool {
        AnimatedWindowMover.animationLock.lock()
        let isValid = AnimatedWindowMover.animationIds[windowKey] == animationId
        AnimatedWindowMover.animationLock.unlock()
        return isValid
    }
    
    private func cleanupAnimation(windowKey: ObjectIdentifier, animationId: UUID) {
        AnimatedWindowMover.animationLock.lock()
        if AnimatedWindowMover.animationIds[windowKey] == animationId {
            AnimatedWindowMover.animationIds.removeValue(forKey: windowKey)
        }
        AnimatedWindowMover.animationLock.unlock()
    }
    
    private func animate(windowElement: AccessibilityElement, windowKey: ObjectIdentifier, from startRect: CGRect, to targetRect: CGRect, duration: TimeInterval, animationId: UUID) {
        let frameRate = AnimatedWindowMover.defaultFrameRate
        
        // Calculate total number of frames
        let totalFrames = max(1, Int(duration / frameRate))
        
        for frameIndex in 0..<totalFrames {
            let delay = frameRate * Double(frameIndex)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                // Check if this animation is still valid (hasn't been superseded)
                guard self?.isAnimationValid(windowKey: windowKey, animationId: animationId) == true else { return }
                
                // Calculate progress based on frame index for consistent timing
                let progress = Double(frameIndex + 1) / Double(totalFrames)
                
                // Use ease-out cubic easing for smooth deceleration (similar to macOS animations)
                let easedProgress = self?.easeOutCubic(progress) ?? progress
                
                let currentRect = self?.interpolateRect(from: startRect, to: targetRect, progress: easedProgress) ?? targetRect
                
                // Only adjust size first on the first frame
                windowElement.setFrame(currentRect, adjustSizeFirst: frameIndex == 0)
            }
        }
        
        // Schedule final frame to ensure we reach exactly the target position
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            // Check if this animation is still valid
            guard self?.isAnimationValid(windowKey: windowKey, animationId: animationId) == true else { return }
            
            windowElement.setFrame(targetRect, adjustSizeFirst: false)
            
            // Cleanup animation tracking
            self?.cleanupAnimation(windowKey: windowKey, animationId: animationId)
        }
    }
    
    /// Ease-out cubic easing function for smooth deceleration
    private func easeOutCubic(_ t: Double) -> Double {
        let p = t - 1.0
        return p * p * p + 1.0
    }
    
    /// Interpolate between two rects based on progress (0.0 to 1.0)
    private func interpolateRect(from startRect: CGRect, to endRect: CGRect, progress: Double) -> CGRect {
        let x = startRect.origin.x + (endRect.origin.x - startRect.origin.x) * CGFloat(progress)
        let y = startRect.origin.y + (endRect.origin.y - startRect.origin.y) * CGFloat(progress)
        let width = startRect.size.width + (endRect.size.width - startRect.size.width) * CGFloat(progress)
        let height = startRect.size.height + (endRect.size.height - startRect.size.height) * CGFloat(progress)
        
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

