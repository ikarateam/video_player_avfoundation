#import "FVPVideoPlayerPlugin.h"
#import "FVPVideoPlayerPlugin_Test.h"
#import <AVFoundation/AVFoundation.h>
#import <GLKit/GLKit.h>
#import "./include/video_player_avfoundation/AVAssetTrackUtils.h"
#import "./include/video_player_avfoundation/FVPDisplayLink.h"
#import "./include/video_player_avfoundation/messages.g.h"

#if !__has_feature(objc_arc)
#error Code Requires ARC.
#endif

@interface FVPFrameUpdater : NSObject
@property(nonatomic) int64_t textureId;
@property(nonatomic, weak, readonly) NSObject<FlutterTextureRegistry> *registry;
@property(nonatomic, weak) AVPlayerItemVideoOutput *videoOutput;
@property(nonatomic, assign) CMTime lastKnownAvailableTime;
@end

@implementation FVPFrameUpdater

- (FVPFrameUpdater *)initWithRegistry:(NSObject<FlutterTextureRegistry> *)registry {
    NSAssert(self, @"super init cannot be nil");
    if (self == nil) return nil;
    _registry = registry;
    _lastKnownAvailableTime = kCMTimeInvalid;
    return self;
}

- (void)displayLinkFired {
    CMTime outputItemTime = [self.videoOutput itemTimeForHostTime:CACurrentMediaTime()];
    if ([self.videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
        _lastKnownAvailableTime = outputItemTime;
        [_registry textureFrameAvailable:_textureId];
    }
}

@end

@interface FVPDefaultAVFactory : NSObject <FVPAVFactory>
@end

@implementation FVPDefaultAVFactory

- (AVPlayer *)playerWithPlayerItem:(AVPlayerItem *)playerItem {
    return [AVPlayer playerWithPlayerItem:playerItem];
}

- (AVPlayerItemVideoOutput *)videoOutputWithPixelBufferAttributes:(NSDictionary<NSString *, id> *)attributes {
    return [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attributes];
}

@end

@interface FVPDefaultDisplayLinkFactory : NSObject <FVPDisplayLinkFactory>
@end

@implementation FVPDefaultDisplayLinkFactory

- (FVPDisplayLink *)displayLinkWithRegistrar:(id<FlutterPluginRegistrar>)registrar
                                    callback:(void (^)(void))callback {
    return [[FVPDisplayLink alloc] initWithRegistrar:registrar callback:callback];
}

@end

#pragma mark -

@interface FVPVideoPlayer ()
@property(readonly, nonatomic) AVPlayerItemVideoOutput *videoOutput;
@property(nonatomic, weak) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, readonly) CALayer *flutterViewLayer;
@property(nonatomic) FlutterEventChannel *eventChannel;
@property(nonatomic) FlutterEventSink eventSink;
@property(nonatomic) CGAffineTransform preferredTransform;
@property(nonatomic, readonly) BOOL disposed;
@property(nonatomic, readonly) BOOL isPlaying;
@property(nonatomic) BOOL isLooping;
@property(nonatomic, readonly) BOOL isInitialized;
@property(nonatomic) FVPFrameUpdater *frameUpdater;
@property(nonatomic) FVPDisplayLink *displayLink;
@property(nonatomic, assign) BOOL waitingForFrame;

// Lưu trạng thái AVAudioSession trước khi thay đổi
@property(nonatomic) NSString *previousCategory;
@property(nonatomic) AVAudioSessionCategoryOptions previousOptions;

- (instancetype)initWithURL:(NSURL *)url
               frameUpdater:(FVPFrameUpdater *)frameUpdater
                displayLink:(FVPDisplayLink *)displayLink
                httpHeaders:(nonnull NSDictionary<NSString *, NSString *> *)headers
        avFactory:(id<FVPAVFactory>)avFactory
        registrar:(NSObject<FlutterPluginRegistrar> *)registrar;

- (void)expectFrame;
- (void)appDidEnterBackground;
- (void)appWillEnterForeground;
- (void)restorePreviousAudioSession; // Khôi phục lại trạng thái AVAudioSession

@end

static void *timeRangeContext = &timeRangeContext;
static void *statusContext = &statusContext;
static void *presentationSizeContext = &presentationSizeContext;
static void *durationContext = &durationContext;
static void *playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void *rateContext = &rateContext;

@implementation FVPVideoPlayer

- (instancetype)initWithAsset:(NSString *)asset
                 frameUpdater:(FVPFrameUpdater *)frameUpdater
                  displayLink:(FVPDisplayLink *)displayLink
                    avFactory:(id<FVPAVFactory>)avFactory
                    registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    NSString *path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
#if TARGET_OS_OSX
    if (!path) {
    path = [NSURL URLWithString:asset relativeToURL:NSBundle.mainBundle.bundleURL].path;
  }
#endif
    return [self initWithURL:[NSURL fileURLWithPath:path]
                frameUpdater:frameUpdater
                 displayLink:displayLink
                 httpHeaders:@{}
                   avFactory:avFactory
                   registrar:registrar];
}

- (instancetype)initWithURL:(NSURL *)url
               frameUpdater:(FVPFrameUpdater *)frameUpdater
                displayLink:(FVPDisplayLink *)displayLink
                httpHeaders:(nonnull NSDictionary<NSString *, NSString *> *)headers
        avFactory:(id<FVPAVFactory>)avFactory
        registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    self = [super init];
    if (self) {

        // Lưu trạng thái AVAudioSession ban đầu
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        self.previousCategory = audioSession.category;
        self.previousOptions = audioSession.categoryOptions;

        NSDictionary<NSString *, id> *options = nil;
        if ([headers count] != 0) {
            options = @{@"AVURLAssetHTTPHeaderFieldsKey" : headers};
        }
        AVURLAsset *urlAsset = [AVURLAsset URLAssetWithURL:url options:options];
        AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:urlAsset];

        _player = [avFactory playerWithPlayerItem:item];
        _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

        _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
        [self.flutterViewLayer addSublayer:_playerLayer];

        _registrar = registrar;
        _frameUpdater = frameUpdater;

        _displayLink = displayLink;
        NSDictionary *pixBuffAttributes = @{
                (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
        };
        _videoOutput = [avFactory videoOutputWithPixelBufferAttributes:pixBuffAttributes];
        frameUpdater.videoOutput = _videoOutput;

        [self addObserversForItem:item player:_player];
        [urlAsset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:^{
            if ([urlAsset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
                NSArray *tracks = [urlAsset tracksWithMediaType:AVMediaTypeVideo];
                if ([tracks count] > 0) {
                    AVAssetTrack *videoTrack = tracks[0];
                    [videoTrack loadValuesAsynchronouslyForKeys:@[ @"preferredTransform" ]
                                              completionHandler:^{
                                                  if (self->_disposed) return;
                                                  if ([videoTrack statusOfValueForKey:@"preferredTransform" error:nil] == AVKeyValueStatusLoaded) {
                                                      self->_preferredTransform = FVPGetStandardizedTransformForTrack(videoTrack);
                                                      AVMutableVideoComposition *videoComposition = [self getVideoCompositionWithTransform:self->_preferredTransform withAsset:urlAsset withVideoTrack:videoTrack];
                                                      item.videoComposition = videoComposition;
                                                  }
                                              }];
                }
            }
        }];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appDidEnterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appWillEnterForeground)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
    }
    return self;
}

// Khi vào nền, dừng phát video
- (void)appDidEnterBackground {
    
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    // Kiểm tra nếu hiện tại không phải là Playback thì set lại Playback
    if (![audioSession.category isEqualToString:AVAudioSessionCategoryPlayback]) {
        self.previousCategory = audioSession.category;
        self.previousOptions = audioSession.categoryOptions;
        [audioSession setCategory:AVAudioSessionCategoryPlayback error:nil];
    }
    _playerLayer.player = nil;

}

// Khi quay lại app, khôi phục phát video và khôi phục trạng thái AVAudioSession
- (void)appWillEnterForeground {
    _playerLayer.player = _player;
    f (_player.status == AVPlayerStatusReadyToPlay && _player.currentItem.status == AVPlayerItemStatusReadyToPlay) {
        CMTime currentTime = _player.currentTime;

        // Seek đến thời gian hiện tại với độ chính xác cao để đảm bảo phát lại mượt mà
        [_player seekToTime:currentTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
            if (finished) {
                // Chỉ bắt đầu phát lại nếu thao tác seek hoàn tất
                [_player play];
            }
        }];
    } else {
        NSLog(@"Player chưa sẵn sàng phát lại.");
    }
    [self restorePreviousAudioSession];  // Khôi phục lại AVAudioSession ban đầu nếu cần
}

- (void)restorePreviousAudioSession {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    if (![audioSession.category isEqualToString:self.previousCategory]) {
        [audioSession setCategory:self.previousCategory withOptions:self.previousOptions error:nil];
    }
    [audioSession setActive:YES error:nil];
}

- (void)dealloc {
    if (!_disposed) {
        [self removeKeyValueObservers];
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

- (void)addObserversForItem:(AVPlayerItem *)item player:(AVPlayer *)player {
    [item addObserver:self
           forKeyPath:@"loadedTimeRanges"
              options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
              context:timeRangeContext];
    [item addObserver:self
           forKeyPath:@"status"
              options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
              context:statusContext];
    [item addObserver:self
           forKeyPath:@"presentationSize"
              options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
              context:presentationSizeContext];
    [item addObserver:self
           forKeyPath:@"duration"
              options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
              context:durationContext];
    [item addObserver:self
           forKeyPath:@"playbackLikelyToKeepUp"
              options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
              context:playbackLikelyToKeepUpContext];

    [player addObserver:self
             forKeyPath:@"rate"
                options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                context:rateContext];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(itemDidPlayToEndTime:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];
}

- (void)itemDidPlayToEndTime:(NSNotification *)notification {
    if (_isLooping) {
        AVPlayerItem *p = [notification object];
        [p seekToTime:kCMTimeZero completionHandler:nil];
    } else {
        if (_eventSink) {
            _eventSink(@{@"event" : @"completed"});
        }
    }
//    if (_isLooping) {
//        AVPlayerItem *p = [notification object];
//        [p seekToTime:kCMTimeZero completionHandler:nil];
//    } else {
//        if (_eventSink) {
//            _eventSink(@{@"event" : @"completed"});
//        }
//    }
}

const int64_t TIME_UNSET = -9223372036854775807;

NS_INLINE int64_t FVPCMTimeToMillis(CMTime time) {
    if (CMTIME_IS_INDEFINITE(time)) return TIME_UNSET;
    if (time.timescale == 0) return 0;
    return time.value * 1000 / time.timescale;
}

NS_INLINE CGFloat radiansToDegrees(CGFloat radians) {
    CGFloat degrees = GLKMathRadiansToDegrees((float)radians);
    if (degrees < 0) {
        return degrees + 360;
    }
    return degrees;
};

- (AVMutableVideoComposition *)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                      withAsset:(AVAsset *)asset
                                                 withVideoTrack:(AVAssetTrack *)videoTrack {
    AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
    AVMutableVideoCompositionLayerInstruction *layerInstruction = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:videoTrack];
    [layerInstruction setTransform:_preferredTransform atTime:kCMTimeZero];

    AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
    instruction.layerInstructions = @[ layerInstruction ];
    videoComposition.instructions = @[ instruction ];

    CGFloat width = videoTrack.naturalSize.width;
    CGFloat height = videoTrack.naturalSize.height;
    NSInteger rotationDegrees = (NSInteger)round(radiansToDegrees(atan2(_preferredTransform.b, _preferredTransform.a)));
    if (rotationDegrees == 90 || rotationDegrees == 270) {
        width = videoTrack.naturalSize.height;
        height = videoTrack.naturalSize.width;
    }
    videoComposition.renderSize = CGSizeMake(width, height);
    videoComposition.frameDuration = CMTimeMake(1, 30);

    return videoComposition;
}

- (void)observeValueForKeyPath:(NSString *)path
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (context == timeRangeContext) {
        if (_eventSink != nil) {
            NSMutableArray<NSArray<NSNumber *> *> *values = [[NSMutableArray alloc] init];
            for (NSValue *rangeValue in [object loadedTimeRanges]) {
                CMTimeRange range = [rangeValue CMTimeRangeValue];
                int64_t start = FVPCMTimeToMillis(range.start);
                [values addObject:@[ @(start), @(start + FVPCMTimeToMillis(range.duration)) ]];
            }
            _eventSink(@{@"event" : @"bufferingUpdate", @"values" : values});
        }
    } else if (context == statusContext) {
        AVPlayerItem *item = (AVPlayerItem *)object;
        switch (item.status) {
            case AVPlayerItemStatusFailed:
                if (_eventSink != nil) {
                    _eventSink([FlutterError errorWithCode:@"VideoError"
                                                   message:[@"Failed to load video: " stringByAppendingString:[item.error localizedDescription]]
                                                   details:nil]);
                }
                break;
            case AVPlayerItemStatusUnknown:
                break;
            case AVPlayerItemStatusReadyToPlay:
                [item addOutput:_videoOutput];
                [self setupEventSinkIfReadyToPlay];
                [self updatePlayingState];
                break;
        }
    } else if (context == presentationSizeContext || context == durationContext) {
        AVPlayerItem *item = (AVPlayerItem *)object;
        if (item.status == AVPlayerItemStatusReadyToPlay) {
            [self setupEventSinkIfReadyToPlay];
            [self updatePlayingState];
        }
    } else if (context == playbackLikelyToKeepUpContext) {
        [self updatePlayingState];
        if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
            if (_eventSink != nil) {
                _eventSink(@{@"event" : @"bufferingEnd"});
            }
        } else {
            if (_eventSink != nil) {
                _eventSink(@{@"event" : @"bufferingStart"});
            }
        }
    } else if (context == rateContext) {
        AVPlayer *player = (AVPlayer *)object;
        if (_eventSink != nil) {
            _eventSink(@{@"event" : @"isPlayingStateUpdate", @"isPlaying" : player.rate > 0 ? @YES : @NO});
        }
    }
}

- (void)updatePlayingState {
    if (!_isInitialized) {
        return;
    }
    if (_isPlaying) {
        [_player play];
    } else {
        [_player pause];
    }
    _displayLink.running = _isPlaying || self.waitingForFrame;
}

- (void)setupEventSinkIfReadyToPlay {
    if (_eventSink && !_isInitialized) {
        AVPlayerItem *currentItem = self.player.currentItem;
        CGSize size = currentItem.presentationSize;
        CGFloat width = size.width;
        CGFloat height = size.height;

        AVAsset *asset = currentItem.asset;
        if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
            void (^trackCompletionHandler)(void) = ^{
                if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
                    return;
                }
                [self performSelector:_cmd onThread:NSThread.mainThread withObject:self waitUntilDone:NO];
            };
            [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:trackCompletionHandler];
            return;
        }

        BOOL hasVideoTracks = [asset tracksWithMediaType:AVMediaTypeVideo].count != 0;
        BOOL hasNoTracks = asset.tracks.count == 0;

        if ((hasVideoTracks || hasNoTracks) && height == CGSizeZero.height &&
            width == CGSizeZero.width) {
            return;
        }
        int64_t duration = [self duration];
        if (duration == 0) {
            return;
        }

        _isInitialized = YES;
        _eventSink(@{
                           @"event" : @"initialized",
                           @"duration" : @(duration),
                           @"width" : @(width),
                           @"height" : @(height)
                   });
    }
}

- (void)play {
    _isPlaying = YES;
    [self updatePlayingState];
}

- (void)pause {
    _isPlaying = NO;
    [self updatePlayingState];
}

- (int64_t)position {
    return FVPCMTimeToMillis([_player currentTime]);
}

- (int64_t)duration {
    return FVPCMTimeToMillis([[[_player currentItem] asset] duration]);
}

- (void)seekTo:(int64_t)location completionHandler:(void (^)(BOOL))completionHandler {
    CMTime previousCMTime = _player.currentTime;
    CMTime targetCMTime = CMTimeMake(location, 1000);
    CMTimeValue duration = _player.currentItem.asset.duration.value;
    CMTime tolerance = location == duration ? CMTimeMake(1, 1000) : kCMTimeZero;
    [_player seekToTime:targetCMTime
        toleranceBefore:tolerance
         toleranceAfter:tolerance
      completionHandler:^(BOOL completed) {
          if (CMTimeCompare(self.player.currentTime, previousCMTime) != 0) {
              [self expectFrame];
          }
          if (completionHandler) {
              completionHandler(completed);
          }
      }];
}

- (void)expectFrame {
    self.waitingForFrame = YES;
    self.displayLink.running = YES;
}

- (void)setIsLooping:(BOOL)isLooping {
    _isLooping = isLooping;
}

- (void)setVolume:(double)volume {
    _player.volume = (float)((volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume));
}

- (void)setPlaybackSpeed:(double)speed {
    if (speed > 2.0 && !_player.currentItem.canPlayFastForward) {
        if (_eventSink != nil) {
            _eventSink([FlutterError errorWithCode:@"VideoError"
                                           message:@"Video cannot be fast-forwarded beyond 2.0x"
                                           details:nil]);
        }
        return;
    }
    if (speed < 1.0 && !_player.currentItem.canPlaySlowForward) {
        if (_eventSink != nil) {
            _eventSink([FlutterError errorWithCode:@"VideoError"
                                           message:@"Video cannot be slow-forwarded"
                                           details:nil]);
        }
        return;
    }
    _player.rate = speed;
}

- (CVPixelBufferRef)copyPixelBuffer {
    CVPixelBufferRef buffer = NULL;
    CMTime outputItemTime = [_videoOutput itemTimeForHostTime:CACurrentMediaTime()];
    if ([_videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
        buffer = [_videoOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
    } else {
        CMTime lastAvailableTime = self.frameUpdater.lastKnownAvailableTime;
        if (CMTIME_IS_VALID(lastAvailableTime)) {
            buffer = [_videoOutput copyPixelBufferForItemTime:lastAvailableTime itemTimeForDisplay:NULL];
        }
    }

    if (self.waitingForFrame && buffer) {
        self.waitingForFrame = NO;
        if (!self.isPlaying) {
            self.displayLink.running = NO;
        }
    }

    return buffer;
}

- (void)onTextureUnregistered:(NSObject<FlutterTexture> *)texture {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self dispose];
    });
}

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
    _eventSink = nil;
    return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
    _eventSink = events;
    [self setupEventSinkIfReadyToPlay];
    return nil;
}

- (void)disposeSansEventChannel {
    if (_disposed) {
        return;
    }
    _disposed = YES;
    [_playerLayer removeFromSuperlayer];
    _displayLink = nil;
    [self removeKeyValueObservers];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dispose {
    [self disposeSansEventChannel];
    [_eventChannel setStreamHandler:nil];
}

- (CALayer *)flutterViewLayer {
#if TARGET_OS_OSX
    return self.registrar.view.layer;
#else
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIViewController *root = UIApplication.sharedApplication.keyWindow.rootViewController;
#pragma clang diagnostic pop
    return root.view.layer;
#endif
}

- (void)removeKeyValueObservers {
    AVPlayerItem *currentItem = _player.currentItem;
    [currentItem removeObserver:self forKeyPath:@"status"];
    [currentItem removeObserver:self forKeyPath:@"loadedTimeRanges"];
    [currentItem removeObserver:self forKeyPath:@"presentationSize"];
    [currentItem removeObserver:self forKeyPath:@"duration"];
    [currentItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp"];
    [_player removeObserver:self forKeyPath:@"rate"];
}

@end

@interface FVPVideoPlayerPlugin ()
@property(readonly, weak, nonatomic) NSObject<FlutterTextureRegistry> *registry;
@property(readonly, weak, nonatomic) NSObject<FlutterBinaryMessenger> *messenger;
@property(readonly, strong, nonatomic) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, strong) id<FVPDisplayLinkFactory> displayLinkFactory;
@property(nonatomic, strong) id<FVPAVFactory> avFactory;
@end

@implementation FVPVideoPlayerPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FVPVideoPlayerPlugin *instance = [[FVPVideoPlayerPlugin alloc] initWithRegistrar:registrar];
    [registrar publish:instance];
    SetUpFVPAVFoundationVideoPlayerApi(registrar.messenger, instance);
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    return [self initWithAVFactory:[[FVPDefaultAVFactory alloc] init]
                displayLinkFactory:[[FVPDefaultDisplayLinkFactory alloc] init]
                         registrar:registrar];
}

- (instancetype)initWithAVFactory:(id<FVPAVFactory>)avFactory
               displayLinkFactory:(id<FVPDisplayLinkFactory>)displayLinkFactory
                        registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _registry = [registrar textures];
    _messenger = [registrar messenger];
    _registrar = registrar;
    _displayLinkFactory = displayLinkFactory ?: [[FVPDefaultDisplayLinkFactory alloc] init];
    _avFactory = avFactory ?: [[FVPDefaultAVFactory alloc] init];
    _playersByTextureId = [NSMutableDictionary dictionaryWithCapacity:1];
    return self;
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    [self.playersByTextureId.allValues makeObjectsPerformSelector:@selector(disposeSansEventChannel)];
    [self.playersByTextureId removeAllObjects];
    SetUpFVPAVFoundationVideoPlayerApi(registrar.messenger, nil);
}

- (int64_t)onPlayerSetup:(FVPVideoPlayer *)player frameUpdater:(FVPFrameUpdater *)frameUpdater {
    int64_t textureId = [self.registry registerTexture:player];
    frameUpdater.textureId = textureId;
    FlutterEventChannel *eventChannel = [FlutterEventChannel
            eventChannelWithName:[NSString stringWithFormat:@"flutter.io/videoPlayer/videoEvents%lld",
                                                            textureId]
                 binaryMessenger:_messenger];
    [eventChannel setStreamHandler:player];
    player.eventChannel = eventChannel;
    self.playersByTextureId[@(textureId)] = player;

    [player expectFrame];

    return textureId;
}

- (void)initialize:(FlutterError *__autoreleasing *)error {
#if TARGET_OS_IOS
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
#endif

    [self.playersByTextureId
            enumerateKeysAndObjectsUsingBlock:^(NSNumber *textureId, FVPVideoPlayer *player, BOOL *stop) {
                [self.registry unregisterTexture:textureId.unsignedIntegerValue];
                [player dispose];
            }];
    [self.playersByTextureId removeAllObjects];
}

- (nullable NSNumber *)createWithOptions:(nonnull FVPCreationOptions *)options
        error:(FlutterError **)error {
    FVPFrameUpdater *frameUpdater = [[FVPFrameUpdater alloc] initWithRegistry:_registry];
    FVPDisplayLink *displayLink =
            [self.displayLinkFactory displayLinkWithRegistrar:_registrar
                                                     callback:^() {
                                                         [frameUpdater displayLinkFired];
                                                     }];

    FVPVideoPlayer *player;
    if (options.asset) {
        NSString *assetPath;
        if (options.packageName) {
            assetPath = [_registrar lookupKeyForAsset:options.asset fromPackage:options.packageName];
        } else {
            assetPath = [_registrar lookupKeyForAsset:options.asset];
        }
        @try {
            player = [[FVPVideoPlayer alloc] initWithAsset:assetPath
                                              frameUpdater:frameUpdater
                                               displayLink:displayLink
                                                 avFactory:_avFactory
                                                 registrar:self.registrar];
            return @([self onPlayerSetup:player frameUpdater:frameUpdater]);
        } @catch (NSException *exception) {
            *error = [FlutterError errorWithCode:@"video_player" message:exception.reason details:nil];
            return nil;
        }
    } else if (options.uri) {
        player = [[FVPVideoPlayer alloc] initWithURL:[NSURL URLWithString:options.uri]
                                        frameUpdater:frameUpdater
                                         displayLink:displayLink
                                         httpHeaders:options.httpHeaders
                                           avFactory:_avFactory
                                           registrar:self.registrar];
        return @([self onPlayerSetup:player frameUpdater:frameUpdater]);
    } else {
        *error = [FlutterError errorWithCode:@"video_player" message:@"not implemented" details:nil];
        return nil;
    }
}

- (void)disposePlayer:(NSInteger)textureId error:(FlutterError **)error {
    NSNumber *playerKey = @(textureId);
    FVPVideoPlayer *player = self.playersByTextureId[playerKey];
    [self.registry unregisterTexture:textureId];
    [self.playersByTextureId removeObjectForKey:playerKey];
    if (!player.disposed) {
        [player dispose];
    }
}

- (void)setLooping:(BOOL)isLooping forPlayer:(NSInteger)textureId error:(FlutterError **)error {
    FVPVideoPlayer *player = self.playersByTextureId[@(textureId)];
    player.isLooping = isLooping;
}

- (void)setVolume:(double)volume forPlayer:(NSInteger)textureId error:(FlutterError **)error {
    FVPVideoPlayer *player = self.playersByTextureId[@(textureId)];
    [player setVolume:volume];
}

- (void)setPlaybackSpeed:(double)speed forPlayer:(NSInteger)textureId error:(FlutterError **)error {
    FVPVideoPlayer *player = self.playersByTextureId[@(textureId)];
    [player setPlaybackSpeed:speed];
}

- (void)playPlayer:(NSInteger)textureId error:(FlutterError **)error {
    FVPVideoPlayer *player = self.playersByTextureId[@(textureId)];
    [player play];
}

- (nullable NSNumber *)positionForPlayer:(NSInteger)textureId error:(FlutterError **)error {
    FVPVideoPlayer *player = self.playersByTextureId[@(textureId)];
    return @([player position]);
}

- (void)seekTo:(NSInteger)position
     forPlayer:(NSInteger)textureId
    completion:(nonnull void (^)(FlutterError *_Nullable))completion {
    FVPVideoPlayer *player = self.playersByTextureId[@(textureId)];
    [player seekTo:position
 completionHandler:^(BOOL finished) {
     dispatch_async(dispatch_get_main_queue(), ^{
         completion(nil);
     });
 }];
}

- (void)pausePlayer:(NSInteger)textureId error:(FlutterError **)error {
    FVPVideoPlayer *player = self.playersByTextureId[@(textureId)];
    [player pause];
}

- (void)setMixWithOthers:(BOOL)mixWithOthers
                   error:(FlutterError *_Nullable __autoreleasing *)error {
#if TARGET_OS_OSX
#else
    if (mixWithOthers) {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                         withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                               error:nil];
    } else {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    }
#endif
}

@end
