#if os(iOS)
    import UIKit
#else
    import Cocoa
#endif
import CoreImage
import Foundation
import AVFoundation

// MARK: ScreenCaptureOutputPixelBufferDelegate
public protocol ScreenCaptureOutputPixelBufferDelegate: class {
    func didSetSize(size:CGSize)
    func pixelBufferOutput(pixelBuffer:CVPixelBufferRef, timestamp:CMTime)
}

#if os(iOS)
    // MARK: - iOS
    public final class ScreenCaptureSession: NSObject {
        static let defaultFrameInterval:Int = 2
        static let defaultAttributes:[NSString:NSObject] = [
            kCVPixelBufferPixelFormatTypeKey: NSNumber(unsignedInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        
        public var enabledScale:Bool = false
        public var frameInterval:Int = ScreenCaptureSession.defaultFrameInterval
        public var attributes:[NSString:NSObject] {
            get {
                var attributes:[NSString: NSObject] = ScreenCaptureSession.defaultAttributes
                attributes[kCVPixelBufferWidthKey] = size.width * scale
                attributes[kCVPixelBufferHeightKey] = size.height * scale
                attributes[kCVPixelBufferBytesPerRowAlignmentKey] = size.width * scale * 4
                return attributes
            }
        }
        public weak var delegate:ScreenCaptureOutputPixelBufferDelegate?
        
        internal(set) var running:Bool = false
        private var context:CIContext = {
            if let context:CIContext = CIContext(options: [kCIContextUseSoftwareRenderer: NSNumber(bool: false)]) {
                logger.info("cicontext use hardware renderer")
                return context
            }
            logger.info("cicontext use software renderer")
            return CIContext()
        }()
        private let semaphore:dispatch_semaphore_t = dispatch_semaphore_create(1)
        private let lockQueue:dispatch_queue_t = {
            var queue:dispatch_queue_t = dispatch_queue_create(
                "com.github.shogo4405.lf.ScreenCaptureSession.lock", DISPATCH_QUEUE_SERIAL
            )
            dispatch_set_target_queue(queue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0))
            return queue
        }()
        private var colorSpace:CGColorSpaceRef!
        private var displayLink:CADisplayLink!
        
        private var size:CGSize = CGSize() {
            didSet {
                guard size != oldValue else {
                    return
                }
                delegate?.didSetSize(CGSize(width: size.width * scale, height: size.height * scale))
                pixelBufferPool = nil
            }
        }
        private var scale:CGFloat {
            return enabledScale ? UIScreen.mainScreen().scale : 1.0
        }
        
        private var _pixelBufferPool:CVPixelBufferPoolRef?
        private var pixelBufferPool:CVPixelBufferPoolRef! {
            get {
                if (_pixelBufferPool == nil) {
                    var pixelBufferPool:CVPixelBufferPoolRef?
                    CVPixelBufferPoolCreate(nil, nil, attributes, &pixelBufferPool)
                    _pixelBufferPool = pixelBufferPool
                }
                return _pixelBufferPool!
            }
            set {
                _pixelBufferPool = newValue
            }
        }
        
        public override init() {
            super.init()
            size = UIApplication.sharedApplication().delegate!.window!!.bounds.size
        }
        
        public func onScreen(displayLink:CADisplayLink) {
            guard dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) == 0 else {
                return
            }
            dispatch_async(lockQueue) {
                autoreleasepool {
                    self.onScreenProcess(displayLink)
                }
                dispatch_semaphore_signal(self.semaphore)
            }
        }
        
        private func onScreenProcess(displayLink:CADisplayLink) {
            var pixelBuffer:CVPixelBufferRef?
            size = UIApplication.sharedApplication().delegate!.window!!.bounds.size
            CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
            CVPixelBufferLockBaseAddress(pixelBuffer!, 0)
            UIGraphicsBeginImageContextWithOptions(size, false, scale)
            let cgctx:CGContextRef = UIGraphicsGetCurrentContext()!
            dispatch_sync(dispatch_get_main_queue()) {
                UIGraphicsPushContext(cgctx)
                for window:UIWindow in UIApplication.sharedApplication().windows {
                    window.drawViewHierarchyInRect(
                        CGRect(x: 0, y: 0, width: self.size.width, height: self.size.height),
                        afterScreenUpdates: false
                    )
                }
                UIGraphicsPopContext()
            }
            let image:UIImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            context.render(CIImage(CGImage: image.CGImage!), toCVPixelBuffer: pixelBuffer!)
            delegate?.pixelBufferOutput(pixelBuffer!, timestamp: CMTimeMakeWithSeconds(displayLink.timestamp, 1000))
            CVPixelBufferUnlockBaseAddress(pixelBuffer!, 0)
        }
    }
    
    // MARK: Runnable
    extension ScreenCaptureSession: Runnable {
        public func startRunning() {
            dispatch_sync(lockQueue) {
                guard !self.running else {
                    return
                }
                self.running = true
                self.pixelBufferPool = nil
                self.colorSpace = CGColorSpaceCreateDeviceRGB()
                self.displayLink = CADisplayLink(target: self, selector: #selector(ScreenCaptureSession.onScreen(_:)))
                self.displayLink.frameInterval = self.frameInterval
                self.displayLink.addToRunLoop(.mainRunLoop(), forMode: NSRunLoopCommonModes)
            }
        }
        
        public func stopRunning() {
            dispatch_sync(lockQueue) {
                guard self.running else {
                    return
                }
                self.displayLink.invalidate()
                self.displayLink.removeFromRunLoop(.mainRunLoop(), forMode: NSRunLoopCommonModes)
                self.colorSpace = nil
                self.displayLink = nil
                self.running = false
            }
        }
    }
#else
    
    func displayLinkDidOutput(displayLink: DisplayLink,
                              _ inNow: UnsafePointer<CVTimeStamp>,
                                _ inOutputTime: UnsafePointer<CVTimeStamp>,
                                  _ flagsIn: CVOptionFlags,
                                    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
                                      _ displayLinkContext: UnsafeMutablePointer<Void>) -> CVReturn {
        
        let this = unsafeBitCast(displayLinkContext, ScreenCaptureSession.self)
        guard dispatch_semaphore_wait(this.semaphore, DISPATCH_TIME_NOW) == 0 else {
            return kCVReturnSuccess
        }
        dispatch_async(this.lockQueue) {
            autoreleasepool {
                let timestamp = Double(inNow.memory.videoTime) / 1000000000.0
                this.onScreenProcess(displayLink, timestamp:timestamp)
            }
            dispatch_semaphore_signal(this.semaphore)
        }
        return kCVReturnSuccess
    }
    
    typealias DisplayLink = CVDisplayLink
    // MARK: - OSX
    public final class ScreenCaptureSession: NSObject {
        static let defaultFrameInterval:Int = 2
        static let defaultAttributes:[NSString:NSObject] = [
            kCVPixelBufferPixelFormatTypeKey: NSNumber(unsignedInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        
        public var enabledScale:Bool = false
        public var frameInterval:Int = ScreenCaptureSession.defaultFrameInterval
        public var attributes:[NSString:NSObject] {
            get {
                var attributes:[NSString: NSObject] = ScreenCaptureSession.defaultAttributes
                attributes[kCVPixelBufferWidthKey] = size.width * scale
                attributes[kCVPixelBufferHeightKey] = size.height * scale
                attributes[kCVPixelBufferBytesPerRowAlignmentKey] = size.width * scale * 4
                return attributes
            }
        }
        public weak var delegate:ScreenCaptureOutputPixelBufferDelegate?
        
        internal(set) var running:Bool = false
        private var context:CIContext = {
            if let context:CIContext = CIContext(options: [kCIContextUseSoftwareRenderer: NSNumber(bool: false)]) {
                logger.info("cicontext use hardware renderer")
                return context
            }
            logger.info("cicontext use software renderer")
            return CIContext()
        }()
        private let semaphore:dispatch_semaphore_t = dispatch_semaphore_create(1)
        private let lockQueue:dispatch_queue_t = {
            var queue:dispatch_queue_t = dispatch_queue_create(
                "com.github.shogo4405.lf.ScreenCaptureSession.lock", DISPATCH_QUEUE_SERIAL
            )
            dispatch_set_target_queue(queue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0))
            return queue
        }()
        private var colorSpace:CGColorSpaceRef!
        private var displayLink:DisplayLink?
        
        private var size:CGSize = CGSize() {
            didSet {
                guard size != oldValue else {
                    return
                }
                delegate?.didSetSize(CGSize(width: size.width * scale, height: size.height * scale))
                pixelBufferPool = nil
            }
        }
        private var scale:CGFloat {
            return enabledScale ? NSScreen.mainScreen()!.backingScaleFactor : 1.0
        }
        
        private var _pixelBufferPool:CVPixelBufferPoolRef?
        private var pixelBufferPool:CVPixelBufferPoolRef! {
            get {
                if (_pixelBufferPool == nil) {
                    var pixelBufferPool:CVPixelBufferPoolRef?
                    CVPixelBufferPoolCreate(nil, nil, attributes, &pixelBufferPool)
                    _pixelBufferPool = pixelBufferPool
                }
                return _pixelBufferPool!
            }
            set {
                _pixelBufferPool = newValue
            }
        }
        
        public override init() {
            super.init()
            size = CGSize(width:1280, height: 720)
        }
        
        private func CGImageResize(image: CGImage, _ size: CGSize) -> CGImage! {
            let context  = CGBitmapContextCreate(nil, Int(size.width), Int(size.height),
                                                 CGImageGetBitsPerComponent(image),
                                                 CGImageGetBytesPerRow(image),
                                                 CGImageGetColorSpace(image),
                                                 CGImageGetAlphaInfo(image).rawValue);
            CGContextDrawImage(context, CGRect(origin: CGPointZero, size: size), image);
            return CGBitmapContextCreateImage(context);
        }
        
        private func onScreenProcess(displayLink:DisplayLink, timestamp:Double) {
            let mainScreen = NSScreen.mainScreen()!
            let displayID =  CGMainDisplayID()
            
            let capturedImage = CGDisplayCreateImageForRect(UInt32(displayID), mainScreen.frame)!
            let image = CGImageResize(capturedImage, size)
            
            var pixelBuffer:CVPixelBufferRef?
            CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
            CVPixelBufferLockBaseAddress(pixelBuffer!, 0)
            context.render(CIImage(CGImage: image), toCVPixelBuffer: pixelBuffer!)
            let currentTime = Int64(CFAbsoluteTimeGetCurrent())
            let pts = CMTimeMake(currentTime*1000, 1000)

            delegate?.pixelBufferOutput(pixelBuffer!, timestamp:  pts)
            CVPixelBufferUnlockBaseAddress(pixelBuffer!, 0)
        }
    }
    
    
    // MARK: Runnable
    extension ScreenCaptureSession: Runnable {
        public func startRunning() {
            dispatch_sync(lockQueue) {
                guard !self.running else {
                    return
                }
                self.running = true
                self.pixelBufferPool = nil
                self.colorSpace = CGColorSpaceCreateDeviceRGB()
                
                let displayID = CGMainDisplayID();
                let _ = CVDisplayLinkCreateWithCGDisplay(displayID, &self.displayLink)
                
                let success = CVDisplayLinkSetOutputCallback(self.displayLink!, displayLinkDidOutput, UnsafeMutablePointer<Void>(unsafeAddressOf(self)))
                if success != kCVReturnSuccess {
                    print("Error starting DisplayLink")
                }
                CVDisplayLinkStart(self.displayLink!)
            }
        }
        
        public func stopRunning() {
            dispatch_sync(lockQueue) {
                guard self.running else {
                    return
                }
                if let link = self.displayLink {
                    CVDisplayLinkStop(link)
                }
                self.colorSpace = nil
                self.displayLink = nil
                self.running = false
            }
        }
    }
    
#endif
