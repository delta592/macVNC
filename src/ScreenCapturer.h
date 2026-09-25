#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScreenCapturer : NSObject <SCStreamDelegate, SCStreamOutput>

@property (nonatomic, assign, readonly) int maxFPS;
@property (nonatomic, assign, readonly) double scale;
@property (nonatomic, assign, readonly) BOOL showsCursor;

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID
                         maxFPS:(int)maxFPS
                          scale:(double)scale
                    showsCursor:(BOOL)showsCursor
                   frameHandler:(nonnull void (^)(CMSampleBufferRef sampleBuffer))frameHandler
                   errorHandler:(nonnull void (^)(NSError *error))errorHandler;

- (void)startCapture;
- (void)stopCapture;

@end

NS_ASSUME_NONNULL_END
