#import "SimCamPreviewLayerDriver.h"
#import "SimCamSharedFrameReader.h"
#import <QuartzCore/QuartzCore.h>

static NSString * const kSimCamSharedPath = @"/tmp/SimCam.bgra";
static const CFTimeInterval kStaleAfter = 1.0;  // seconds

@interface SimCamPreviewLayerDriver ()
@property (nonatomic, weak) CALayer *layer;
// A plain sublayer we own and paint into. Painting the target layer's
// own `contents` does NOT work when the target is an
// `AVCaptureVideoPreviewLayer` (the class it is on the `setSession:`
// hook path) — that layer renders its capture session through a private
// path and ignores `contents`. A sublayer renders above the (empty)
// video and displays our frames reliably. Also correct for the plain
// view layers the picker-walker path attaches to.
@property (nonatomic, strong, nullable) CALayer *overlay;
@property (nonatomic, strong) SimCamSharedFrameReader *reader;
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval lastFreshFrameTime;
@property (nonatomic, assign) BOOL showingPlaceholder;
@property (nonatomic, assign) BOOL loggedFirstPaint;
@property (nonatomic, strong, nullable) UIImage *cachedPlaceholder;
@end

@implementation SimCamPreviewLayerDriver

- (instancetype)initWithLayer:(CALayer *)layer {
    if ((self = [super init])) {
        _layer = layer;
        _reader = [[SimCamSharedFrameReader alloc] initWithPath:kSimCamSharedPath];
        _lastFreshFrameTime = 0;
        _showingPlaceholder = NO;
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc {
    [_displayLink invalidate];
    _displayLink = nil;
}

/// Lazily create (and keep parented + sized to) the overlay sublayer we
/// paint into. Re-parents if the target layer changed.
- (CALayer *)overlayInLayer:(CALayer *)layer {
    CALayer *overlay = self.overlay;
    if (overlay == nil || overlay.superlayer != layer) {
        overlay = [CALayer layer];
        overlay.zPosition = 1000;        // above the preview layer's video
        overlay.masksToBounds = YES;
        [layer addSublayer:overlay];
        self.overlay = overlay;
    }
    overlay.frame = layer.bounds;        // track resize / rotation
    return overlay;
}

- (void)tick {
    CALayer *layer = self.layer;
    if (layer == nil) {
        [self.displayLink invalidate];
        self.displayLink = nil;
        return;
    }

    UIImage *image = [self.reader latestImage];

    // Disable implicit animations — contents change every frame, and a
    // per-frame cross-fade would smear the video.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (image != nil) {
        self.lastFreshFrameTime = CACurrentMediaTime();
        self.showingPlaceholder = NO;
        CALayer *overlay = [self overlayInLayer:layer];
        if (!self.loggedFirstPaint) {
            self.loggedFirstPaint = YES;
            NSLog(@"[SimCamInject] painting frames into overlay sublayer (%.0fx%.0f)",
                  image.size.width, image.size.height);
        }
        overlay.contents = (__bridge id)image.CGImage;
        // Black background so the aspect-fit letterbox bands are black,
        // not whatever default gray the underlying CAM* view uses.
        overlay.backgroundColor = [UIColor blackColor].CGColor;

        // Per-frame display preferences come through the shared-buffer
        // header (set by the Mac HUD). Default is Fit + no mirror, which
        // matches a native camera app's "what you see is what you save"
        // contract; the user can flip these in the HUD without restart.
        uint32_t flags = self.reader.latestFlags;
        overlay.contentsGravity = (flags & kSimCamFlagFillGravity)
            ? kCAGravityResizeAspectFill
            : kCAGravityResizeAspect;
        overlay.affineTransform = (flags & kSimCamFlagMirror)
            ? CGAffineTransformMakeScale(-1, 1)
            : CGAffineTransformIdentity;
        [CATransaction commit];
        return;
    }

    // No new frame this tick — decide whether to show the placeholder.
    CFTimeInterval staleness = (self.lastFreshFrameTime == 0)
        ? kStaleAfter + 1
        : CACurrentMediaTime() - self.lastFreshFrameTime;
    if (staleness > kStaleAfter && !self.showingPlaceholder) {
        UIImage *placeholder = [self placeholderImage];
        if (placeholder != nil) {
            CALayer *overlay = [self overlayInLayer:layer];
            overlay.contents = (__bridge id)placeholder.CGImage;
            overlay.contentsGravity = kCAGravityResizeAspect;
            overlay.affineTransform = CGAffineTransformIdentity;
            self.showingPlaceholder = YES;
        }
    }
    [CATransaction commit];
}

- (UIImage *)placeholderImage {
    if (self.cachedPlaceholder != nil) return self.cachedPlaceholder;

    CGSize size = CGSizeMake(900, 600);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        // Dark background.
        [[UIColor colorWithWhite:0.07 alpha:1.0] setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));

        // Centered title + subtitle.
        NSString *title = @"No camera signal";
        NSString *subtitle = @"Start SimCam from the menu bar to see your Mac camera here.";

        UIFont *titleFont = [UIFont systemFontOfSize:46 weight:UIFontWeightSemibold];
        UIFont *subtitleFont = [UIFont systemFontOfSize:24 weight:UIFontWeightRegular];

        NSDictionary *titleAttrs = @{
            NSFontAttributeName: titleFont,
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.92 alpha:1.0],
        };
        NSDictionary *subtitleAttrs = @{
            NSFontAttributeName: subtitleFont,
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.55 alpha:1.0],
        };

        CGSize titleSize = [title sizeWithAttributes:titleAttrs];
        CGSize subtitleSize = [subtitle sizeWithAttributes:subtitleAttrs];

        CGFloat totalH = titleSize.height + 16 + subtitleSize.height;
        CGFloat startY = (size.height - totalH) / 2.0;

        [title drawAtPoint:CGPointMake((size.width - titleSize.width) / 2.0, startY)
            withAttributes:titleAttrs];
        [subtitle drawAtPoint:CGPointMake((size.width - subtitleSize.width) / 2.0,
                                          startY + titleSize.height + 16)
               withAttributes:subtitleAttrs];
    }];

    self.cachedPlaceholder = image;
    return image;
}

@end
