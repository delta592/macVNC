#import "ScreenCapturer.h"

@interface ScreenCapturer ()

@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign, readwrite) int maxFPS;
@property (nonatomic, assign, readwrite) double scale;
@property (nonatomic, assign, readwrite) BOOL showsCursor;
@property (nonatomic, strong) SCStream *stream;

@property (nonatomic, copy, nonnull) void (^frameHandler)(CMSampleBufferRef sampleBuffer);
@property (nonatomic, copy, nonnull) void (^errorHandler)(NSError *error);

@end


@implementation ScreenCapturer

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID
                         maxFPS:(int)maxFPS
                          scale:(double)scale
                    showsCursor:(BOOL)showsCursor
                   frameHandler:(void (^)(CMSampleBufferRef))frameHandler
                   errorHandler:(void (^)(NSError *))errorHandler {
    if (self = [super init]) {
        _displayID = displayID;
        _maxFPS = maxFPS > 0 ? maxFPS : 60;
        _scale = scale > 0.0 ? scale : 1.0;
        _showsCursor = showsCursor;
        _frameHandler = [frameHandler copy];
        _errorHandler = [errorHandler copy];
    }
    return self;
}

- (void)startCapture {
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        if (error) {
            self.errorHandler(error);
            return;
        }

        SCDisplay *display = content.displays[[content.displays indexOfObjectPassingTest:^BOOL(SCDisplay *_Nonnull d, NSUInteger idx, BOOL *_Nonnull stop) {
                    return d.displayID == self.displayID;
                }]];

        if (!display) {
            NSError *noDisplayError = [NSError errorWithDomain:@"ScreenCapturerErrorDomain"
                                                          code:1
                                                      userInfo:@{NSLocalizedDescriptionKey : @"Display not available for capture"}];
            self.errorHandler(noDisplayError);
            return;
        }

        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        int outW = (int)lround((double)display.width * self.scale);
        int outH = (int)lround((double)display.height * self.scale);
        if (outW < 1)
            outW = 1;
        if (outH < 1)
            outH = 1;
        /* LibVNC / many viewers prefer width multiple of 4. */
        outW = (outW + 3) & ~3;

        config.width = outW;
        config.height = outH;
        config.minimumFrameInterval = CMTimeMake(1, self.maxFPS);
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.showsCursor = self.showsCursor;
        if ([config respondsToSelector:@selector(setQueueDepth:)]) {
            /* Keep capture backlog small so dropped frames stay bounded. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
            config.queueDepth = 3;
#pragma clang diagnostic pop
        }

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:(display) excludingWindows:(@[])];
        self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];

        NSError *addOutputError = nil;
        [self.stream addStreamOutput:self
                                type:SCStreamOutputTypeScreen
                  sampleHandlerQueue:dispatch_queue_create("net.macvnc.capture", NULL)
                               error:&addOutputError];
        if (addOutputError) {
            self.errorHandler(addOutputError);
            return;
        }

        [self.stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
            if (startError) {
                self.errorHandler(startError);
            }
        }];
    }];
}

- (void)stopCapture {
    [self.stream stopCaptureWithCompletionHandler:^(NSError * _Nullable stopError) {
        if (stopError) {
            self.errorHandler(stopError);
        }
        self.stream = nil;
    }];
}


/*
  SCStreamDelegate methods
*/

- (void) stream:(SCStream *) stream didStopWithError:(NSError *) error {
    self.errorHandler(error);
}


/*
  SCStreamOutput methods
*/

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type == SCStreamOutputTypeScreen) {
        self.frameHandler(sampleBuffer);
    }
}

@end
