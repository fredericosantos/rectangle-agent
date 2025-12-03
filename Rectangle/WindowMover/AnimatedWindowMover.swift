//
//  AnimatedWindowMover.swift
//  Rectangle
//
//  Created for window animation feature
//

import Foundation

class AnimatedWindowMover: WindowMover {
    
    private static let defaultFrameRate: TimeInterval = 1.0 / 60.0 // 60 FPS
    
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
        
        animate(windowElement: windowElement, from: startRect, to: targetRect, duration: duration)
    }
    
    private func animate(windowElement: AccessibilityElement, from startRect: CGRect, to targetRect: CGRect, duration: TimeInterval) {
        let startTime = CACurrentMediaTime()
        let frameRate = AnimatedWindowMover.defaultFrameRate
        
        // Calculate total number of frames
        let totalFrames = Int(ceil(duration / frameRate))
        
        for frameIndex in 0...totalFrames {
            let delay = frameRate * Double(frameIndex)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let elapsed = CACurrentMediaTime() - startTime
                let progress = min(elapsed / duration, 1.0)
                
                // Use ease-out cubic easing for smooth deceleration (similar to macOS animations)
                let easedProgress = self.easeOutCubic(progress)
                
                let currentRect = self.interpolateRect(from: startRect, to: targetRect, progress: easedProgress)
                
                // Only adjust size first on the first frame
                windowElement.setFrame(currentRect, adjustSizeFirst: frameIndex == 0)
            }
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

