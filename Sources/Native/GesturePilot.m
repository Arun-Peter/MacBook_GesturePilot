#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>
#import <dlfcn.h>
#import "GPClickRecognizer.h"

typedef NS_ENUM(NSInteger, GPSwipeDirection) {
    GPSwipeDirectionUp = 0,
    GPSwipeDirectionDown = 1,
    GPSwipeDirectionLeft = 2,
    GPSwipeDirectionRight = 3,
};

typedef NS_ENUM(NSInteger, GPGestureAction) {
    GPGestureActionNone = 0,
    GPGestureActionMinimizeAll = 1,
    GPGestureActionRestore = 2,
    GPGestureActionToggle = 3,
    GPGestureActionMinimizeCurrent = 4,
    GPGestureActionMaximizeCurrent = 5,
    GPGestureActionMissionControl = 6,
    GPGestureActionAppExpose = 7,
    GPGestureActionCloseCurrent = 8,
    GPGestureActionQuitCurrent = 9,
};

typedef NS_ENUM(NSInteger, GPInputDeviceKind) {
    GPInputDeviceKindUnknown = -1,
    GPInputDeviceKindTrackpad = 0,
    GPInputDeviceKindMagicMouse = 1,
};

static NSString *const GPEnabledKey = @"gesturePilot.enabled";
static NSString *const GPSensitivityKey = @"gesturePilot.sensitivity";
static NSString *const GPFingerCountKey = @"gesturePilot.fingerCount";
static NSString *const GPMouseEnabledKey = @"gesturePilot.mouse.enabled";
static NSString *const GPMouseSensitivityKey = @"gesturePilot.mouse.sensitivity";
static NSString *const GPWelcomeKey = @"gesturePilot.didShowWelcome";

static NSString *GPClickActionKey(GPInputDeviceKind deviceKind) {
    return deviceKind == GPInputDeviceKindMagicMouse
        ? @"gesturePilot.mouse.click.action" : @"gesturePilot.click.action";
}

static NSString *GPActionKey(GPSwipeDirection direction) {
    return [NSString stringWithFormat:@"gesturePilot.action.%ld", (long)direction];
}

static NSString *GPMouseActionKey(GPSwipeDirection direction) {
    return [NSString stringWithFormat:@"gesturePilot.mouse.action.%ld", (long)direction];
}

static NSString *GPActionKeyForDevice(GPInputDeviceKind deviceKind,
                                      GPSwipeDirection direction) {
    return deviceKind == GPInputDeviceKindMagicMouse
        ? GPMouseActionKey(direction)
        : GPActionKey(direction);
}

static NSString *GPDeviceName(GPInputDeviceKind deviceKind) {
    return deviceKind == GPInputDeviceKindMagicMouse ? @"Magic Mouse" : @"Trackpad";
}

static GPInputDeviceKind GPDeviceKindForFamilyID(int32_t familyID) {
    switch (familyID) {
        case 112:
        case 113:
            return GPInputDeviceKindMagicMouse;
        case 98:
        case 99:
        case 100:
        case 101:
        case 102:
        case 103:
        case 104:
        case 108:
        case 109:
        case 128:
        case 129:
        case 130:
            return GPInputDeviceKindTrackpad;
        default:
            return GPInputDeviceKindUnknown;
    }
}

static NSString *GPDirectionName(GPSwipeDirection direction) {
    switch (direction) {
        case GPSwipeDirectionUp: return @"Swipe Up";
        case GPSwipeDirectionDown: return @"Swipe Down";
        case GPSwipeDirectionLeft: return @"Swipe Left";
        case GPSwipeDirectionRight: return @"Swipe Right";
    }
}

static NSString *GPActionName(GPGestureAction action) {
    switch (action) {
        case GPGestureActionNone: return @"No Action";
        case GPGestureActionMinimizeAll: return @"Minimize All Windows";
        case GPGestureActionRestore: return @"Restore Minimized Windows";
        case GPGestureActionToggle: return @"Toggle Minimize / Restore";
        case GPGestureActionMinimizeCurrent: return @"Minimize Current Window";
        case GPGestureActionMaximizeCurrent: return @"Maximize Current Window";
        case GPGestureActionMissionControl: return @"Mission Control";
        case GPGestureActionAppExpose: return @"App Exposé";
        case GPGestureActionCloseCurrent: return @"Close Current Window";
        case GPGestureActionQuitCurrent: return @"Quit Current App";
    }
}

static BOOL GPIsOverviewAction(GPGestureAction action) {
    return action == GPGestureActionMissionControl || action == GPGestureActionAppExpose;
}

// Launch Apple's helper through LaunchServices. NSDistributedNotificationCenter
// does not deliver the private CoreDock messages used by this helper.
static void GPLaunchOverview(GPGestureAction action, void (^completion)(NSError *error)) {
    NSURL *url = [NSURL fileURLWithPath:@"/System/Applications/Mission Control.app"];
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.activates = NO; // App Exposé must keep targeting the user's frontmost app.
    configuration.createsNewApplicationInstance = YES; // Deliver arguments on every gesture.
    configuration.arguments = @[action == GPGestureActionAppExpose ? @"2" : @"0"];
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url
                                      configuration:configuration
                                  completionHandler:^(NSRunningApplication *app, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error ?: (app ? nil : [NSError errorWithDomain:@"GesturePilot"
                                                                code:1
                                                            userInfo:@{NSLocalizedDescriptionKey:
                                                                @"macOS did not launch the overview."}]));
        });
    }];
}

static BOOL GPClassifySwipe(CGFloat deltaX,
                            CGFloat deltaY,
                            CGFloat minimumDistance,
                            GPSwipeDirection *direction) {
    CGFloat horizontal = fabs(deltaX);
    CGFloat vertical = fabs(deltaY);
    CGFloat dominant = MAX(horizontal, vertical);
    const CGFloat dominanceRatio = 1.25;

    if (dominant < minimumDistance) return NO;

    if (vertical > horizontal * dominanceRatio) {
        *direction = deltaY > 0 ? GPSwipeDirectionUp : GPSwipeDirectionDown;
        return YES;
    }

    if (horizontal > vertical * dominanceRatio) {
        *direction = deltaX > 0 ? GPSwipeDirectionRight : GPSwipeDirectionLeft;
        return YES;
    }

    return NO;
}

#pragma mark - Private multitouch types

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;
    int32_t state;
    int32_t fingerID;
    int32_t handID;
    MTVector normalizedVector;
    float totalCapacitance;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absoluteVector;
    int32_t field14;
    int32_t field15;
    float density;
} MTTouch;

_Static_assert(sizeof(MTTouch) == 96, "Unexpected MTTouch layout");

typedef int32_t (*MTContactCallback)(void *device,
                                     MTTouch *touches,
                                     int32_t touchCount,
                                     double timestamp,
                                     int32_t frame);
typedef void *(*MTDeviceCreateDefaultFunction)(void);
typedef CFArrayRef (*MTDeviceCreateListFunction)(void);
typedef void (*MTDeviceReleaseFunction)(void *device);
typedef int32_t (*MTDeviceStartFunction)(void *device, int32_t mode);
typedef int32_t (*MTDeviceStopFunction)(void *device);
typedef void (*MTRegisterCallbackFunction)(void *device, MTContactCallback callback);
typedef void (*MTUnregisterCallbackFunction)(void *device, MTContactCallback callback);
typedef int32_t (*MTDeviceGetFamilyIDFunction)(void *device, int32_t *familyID);

@protocol GPMultitouchDetectorDelegate <NSObject>
- (void)detectorDidRecognizeDirection:(GPSwipeDirection)direction
                           fromDevice:(GPInputDeviceKind)deviceKind;
- (void)detectorStatusDidChange:(NSString *)status;
- (void)detectorDidRecognizeThreeFingerClickFromDevice:(GPInputDeviceKind)deviceKind;
@end

typedef NS_ENUM(NSInteger, GPRecognitionState) {
    GPRecognitionStateIdle,
    GPRecognitionStateTracking,
    GPRecognitionStateTriggered,
    GPRecognitionStateCancelled,
};

#define GPMaxMultitouchDevices 16

typedef struct {
    void *device;
    int32_t familyID;
    GPInputDeviceKind kind;
    GPRecognitionState recognitionState;
    CGFloat originX;
    CGFloat originY;
    GPClickChord clickChord;
    BOOL running;
} GPTrackedDevice;

@interface GPMultitouchDetector : NSObject {
    void *_frameworkHandle;
    MTDeviceCreateDefaultFunction _createDefault;
    MTDeviceCreateListFunction _createList;
    MTDeviceReleaseFunction _releaseDevice;
    MTDeviceStartFunction _startDevice;
    MTDeviceStopFunction _stopDevice;
    MTRegisterCallbackFunction _registerCallback;
    MTUnregisterCallbackFunction _unregisterCallback;
    MTDeviceGetFamilyIDFunction _getFamilyID;
    GPTrackedDevice _devices[GPMaxMultitouchDevices];
    NSInteger _deviceCount;
    CGFloat _trackpadMinimumDistance;
    CGFloat _mouseMinimumDistance;
    NSInteger _trackpadFingerCount;
    BOOL _trackpadEnabled;
    BOOL _mouseEnabled;
    BOOL _running;
    BOOL _trackpadClickEnabled;
    BOOL _mouseClickEnabled;
    CFMachPortRef _clickTap;
    CFRunLoopSourceRef _clickTapSource;
    NSInteger _pendingClickButton;
    void *_pendingClickDevice;
    CGPoint _pendingClickLocation;
    NSTimeInterval _pendingClickTime;
    pid_t _pendingClickTarget;
    BOOL _pendingClickCancelled;
}
@property(nonatomic, weak) id<GPMultitouchDetectorDelegate> delegate;
- (BOOL)start;
- (void)stop;
- (void)setMinimumDistance:(CGFloat)minimumDistance
                 forDevice:(GPInputDeviceKind)deviceKind;
- (void)setTrackpadFingerCount:(NSInteger)fingerCount;
- (void)setEnabled:(BOOL)enabled forDevice:(GPInputDeviceKind)deviceKind;
- (void)processTouches:(MTTouch *)touches
                 count:(int32_t)touchCount
                device:(void *)device;
- (NSString *)availableDeviceSummary;
- (BOOL)isRunningForDevice:(GPInputDeviceKind)deviceKind;
- (void)setClickEnabled:(BOOL)enabled forDevice:(GPInputDeviceKind)deviceKind;
- (BOOL)isClickMonitoringReady;
- (CGEventRef)filterClickEvent:(CGEventRef)event type:(CGEventType)type;
- (BOOL)runClickSelfTests;
- (BOOL)runDeviceShutdownSelfTest;
@end

static __weak GPMultitouchDetector *GPActiveDetector = nil;

static int32_t GPContactFrameCallback(void *device __unused,
                                      MTTouch *touches,
                                      int32_t touchCount,
                                      double timestamp __unused,
                                      int32_t frame __unused) {
    GPMultitouchDetector *detector = GPActiveDetector;
    if (detector) {
        [detector processTouches:touches count:touchCount device:device];
    }
    return 0;
}

static CGEventRef GPClickEventCallback(CGEventTapProxy proxy __unused, CGEventType type,
                                      CGEventRef event, void *context) {
    return [(__bridge GPMultitouchDetector *)context filterClickEvent:event type:type];
}

static BOOL GPTestStopCompleted = NO;
static int32_t GPTestStopDevice(void *device) {
    GPMultitouchDetector *detector = (__bridge GPMultitouchDetector *)device;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [detector processTouches:NULL count:0 device:device];
        dispatch_semaphore_signal(finished);
    });
    GPTestStopCompleted = dispatch_semaphore_wait(finished,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC))) == 0;
    return GPTestStopCompleted ? 0 : -1;
}

static void GPTestReleaseDevice(void *device __unused) {}

@implementation GPMultitouchDetector

- (instancetype)init {
    self = [super init];
    if (self) {
        _trackpadMinimumDistance = 0.075;
        _mouseMinimumDistance = 0.055;
        _trackpadFingerCount = 4;
        _trackpadEnabled = YES;
        _mouseEnabled = YES;
        _pendingClickButton = -1;
    }
    return self;
}

- (BOOL)loadFrameworkIfNeeded {
    if (_frameworkHandle) return YES;

    const char *path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";
    _frameworkHandle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    if (!_frameworkHandle) return NO;

    _createDefault = (MTDeviceCreateDefaultFunction)dlsym(_frameworkHandle, "MTDeviceCreateDefault");
    _createList = (MTDeviceCreateListFunction)dlsym(_frameworkHandle, "MTDeviceCreateList");
    _releaseDevice = (MTDeviceReleaseFunction)dlsym(_frameworkHandle, "MTDeviceRelease");
    _startDevice = (MTDeviceStartFunction)dlsym(_frameworkHandle, "MTDeviceStart");
    _stopDevice = (MTDeviceStopFunction)dlsym(_frameworkHandle, "MTDeviceStop");
    _registerCallback = (MTRegisterCallbackFunction)dlsym(_frameworkHandle, "MTRegisterContactFrameCallback");
    _unregisterCallback = (MTUnregisterCallbackFunction)dlsym(
        _frameworkHandle,
        "MTUnregisterContactFrameCallback"
    );
    _getFamilyID = (MTDeviceGetFamilyIDFunction)dlsym(_frameworkHandle, "MTDeviceGetFamilyID");

    if (!_createDefault || !_createList || !_releaseDevice || !_startDevice ||
        !_stopDevice || !_registerCallback || !_getFamilyID) {
        return NO;
    }

    return YES;
}

- (void)addDeviceLocked:(void *)device
                familyID:(int32_t)familyID
                    kind:(GPInputDeviceKind)kind {
    if (!device || _deviceCount >= GPMaxMultitouchDevices) return;

    CFRetain(device);
    GPTrackedDevice tracked = {
        .device = device,
        .familyID = familyID,
        .kind = kind,
        .recognitionState = GPRecognitionStateIdle,
        .originX = 0,
        .originY = 0,
        .running = NO,
    };
    _devices[_deviceCount] = tracked;
    _deviceCount += 1;
}

- (void)releaseDevices {
    GPTrackedDevice devices[GPMaxMultitouchDevices];
    NSInteger count = 0;
    @synchronized (self) {
        count = _deviceCount;
        memcpy(devices, _devices, sizeof(_devices));
        memset(_devices, 0, sizeof(_devices));
        _deviceCount = 0;
        _running = NO;
        GPActiveDetector = nil;
    }
    // MTDeviceStop waits for callbacks. Never hold the lock those callbacks need.
    for (NSInteger index = 0; index < count; index++) {
        GPTrackedDevice *tracked = &devices[index];
        if (tracked->running) {
            if (_unregisterCallback) {
                _unregisterCallback(tracked->device, GPContactFrameCallback);
            }
            _stopDevice(tracked->device);
        }
        _releaseDevice(tracked->device);
    }
}

- (void)discoverDevicesLocked {
    CFArrayRef deviceList = _createList();
    if (deviceList) {
        CFIndex count = MIN(CFArrayGetCount(deviceList), GPMaxMultitouchDevices);
        for (CFIndex index = 0; index < count; index++) {
            void *device = (void *)CFArrayGetValueAtIndex(deviceList, index);
            int32_t familyID = 0;
            if (!device || _getFamilyID(device, &familyID) != 0) continue;

            GPInputDeviceKind kind = GPDeviceKindForFamilyID(familyID);
            if (kind != GPInputDeviceKindUnknown) {
                [self addDeviceLocked:device familyID:familyID kind:kind];
            }
        }
        CFRelease(deviceList);
    }

    BOOL foundTrackpad = NO;
    for (NSInteger index = 0; index < _deviceCount; index++) {
        foundTrackpad |= _devices[index].kind == GPInputDeviceKindTrackpad;
    }

    if (!foundTrackpad) {
        void *defaultDevice = _createDefault();
        if (defaultDevice) {
            int32_t familyID = 0;
            _getFamilyID(defaultDevice, &familyID);
            [self addDeviceLocked:defaultDevice
                         familyID:familyID
                             kind:GPInputDeviceKindTrackpad];
            _releaseDevice(defaultDevice);
        }
    }
}

- (BOOL)deviceKindEnabledLocked:(GPInputDeviceKind)kind {
    return kind == GPInputDeviceKindMagicMouse ? _mouseEnabled : _trackpadEnabled;
}

- (NSString *)availableDeviceSummary {
    @synchronized (self) {
        NSInteger trackpadCount = 0;
        NSInteger mouseCount = 0;
        for (NSInteger index = 0; index < _deviceCount; index++) {
            trackpadCount += _devices[index].kind == GPInputDeviceKindTrackpad;
            mouseCount += _devices[index].kind == GPInputDeviceKindMagicMouse;
        }
        return [NSString stringWithFormat:@"%ld trackpad%@, %ld Magic Mouse device%@",
            (long)trackpadCount,
            trackpadCount == 1 ? @"" : @"s",
            (long)mouseCount,
            mouseCount == 1 ? @"" : @"s"];
    }
}

- (NSString *)runningDeviceSummaryLocked {
    NSInteger trackpadCount = 0;
    NSInteger mouseCount = 0;
    for (NSInteger index = 0; index < _deviceCount; index++) {
        if (!_devices[index].running) continue;
        trackpadCount += _devices[index].kind == GPInputDeviceKindTrackpad;
        mouseCount += _devices[index].kind == GPInputDeviceKindMagicMouse;
    }
    return [NSString stringWithFormat:@"Listening: %ld trackpad%@, %ld Magic Mouse device%@",
        (long)trackpadCount,
        trackpadCount == 1 ? @"" : @"s",
        (long)mouseCount,
        mouseCount == 1 ? @"" : @"s"];
}

- (BOOL)isRunningForDevice:(GPInputDeviceKind)deviceKind {
    @synchronized (self) {
        for (NSInteger index = 0; index < _deviceCount; index++) {
            if (_devices[index].kind == deviceKind && _devices[index].running) return YES;
        }
        return NO;
    }
}

- (BOOL)start {
    NSString *status = nil;
    @synchronized (self) {
        if (_running) return YES;
    }
    [self releaseDevices];
    @synchronized (self) {
        if (![self loadFrameworkIfNeeded]) {
            status = @"Multitouch framework unavailable";
        } else {
            [self discoverDevicesLocked];

            GPActiveDetector = self;
            for (NSInteger index = 0; index < _deviceCount; index++) {
                GPTrackedDevice *tracked = &_devices[index];
                if (![self deviceKindEnabledLocked:tracked->kind]) continue;

                _registerCallback(tracked->device, GPContactFrameCallback);
                int32_t result = _startDevice(tracked->device, 0);
                tracked->running = result == 0;
                tracked->recognitionState = GPRecognitionStateIdle;
                if (!tracked->running && _unregisterCallback) {
                    _unregisterCallback(tracked->device, GPContactFrameCallback);
                }
                _running |= tracked->running;
            }
            status = _running
                ? [self runningDeviceSummaryLocked]
                : @"No enabled multitouch devices are available";
        }
    }
    [self startClickMonitoring];
    if (_running && ((_trackpadEnabled && _trackpadClickEnabled) ||
                     (_mouseEnabled && _mouseClickEnabled)) && !_clickTap) {
        status = [status stringByAppendingString:@"; clicks need Accessibility — re-enable gestures after granting"];
    }
    [self publishStatus:status];
    return _running;
}

- (void)stop {
    [self stopClickMonitoring];
    [self releaseDevices];
    [self publishStatus:@"Gesture recognition stopped"];
}

- (void)setClickEnabled:(BOOL)enabled forDevice:(GPInputDeviceKind)deviceKind {
    @synchronized (self) {
        if (deviceKind == GPInputDeviceKindMagicMouse) _mouseClickEnabled = enabled;
        else _trackpadClickEnabled = enabled;
    }
}

- (BOOL)isClickMonitoringReady {
    return _clickTap && CGEventTapIsEnabled(_clickTap);
}

- (void)startClickMonitoring {
    if (_clickTap || !_running ||
        !((_trackpadEnabled && _trackpadClickEnabled) ||
          (_mouseEnabled && _mouseClickEnabled))) return;
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventLeftMouseDragged) |
        CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDragged);
    _clickTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault, mask, GPClickEventCallback, (__bridge void *)self);
    if (!_clickTap) return;
    _clickTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _clickTap, 0);
    if (!_clickTapSource) {
        CFRelease(_clickTap);
        _clickTap = NULL;
        return;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), _clickTapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(_clickTap, true);
}

- (void)stopClickMonitoring {
    if (_clickTap) {
        CGEventTapEnable(_clickTap, false);
        CFMachPortInvalidate(_clickTap);
    }
    if (_clickTapSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _clickTapSource, kCFRunLoopCommonModes);
        CFRelease(_clickTapSource);
        _clickTapSource = NULL;
    }
    if (_clickTap) {
        CFRelease(_clickTap);
        _clickTap = NULL;
    }
    @synchronized (self) {
        _pendingClickButton = -1;
        _pendingClickDevice = NULL;
    }
}

- (CGEventRef)filterClickEvent:(CGEventRef)event type:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        @synchronized (self) {
            _pendingClickCancelled = YES;
        }
        if (_clickTap) CGEventTapEnable(_clickTap, true);
        return event;
    }
    BOOL down = type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown;
    BOOL up = type == kCGEventLeftMouseUp || type == kCGEventRightMouseUp;
    NSInteger button = (NSInteger)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    CGPoint location = CGEventGetLocation(event);
    GPInputDeviceKind detectedDevice = GPInputDeviceKindUnknown;
    pid_t target = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    BOOL consume = [self consumeButton:button down:down up:up location:location time:now
        target:target
        detectedDevice:&detectedDevice];
    if (detectedDevice != GPInputDeviceKindUnknown) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != target) return;
            [self.delegate detectorDidRecognizeThreeFingerClickFromDevice:detectedDevice];
        });
    }
    return consume ? NULL : event;
}

- (BOOL)consumeButton:(NSInteger)button down:(BOOL)down up:(BOOL)up
             location:(CGPoint)location time:(NSTimeInterval)now target:(pid_t)target
       detectedDevice:(GPInputDeviceKind *)detectedDevice {
    *detectedDevice = GPInputDeviceKindUnknown;
    BOOL consume = NO;
    @synchronized (self) {
        if (_pendingClickButton >= 0) {
            if (button != _pendingClickButton) {
                _pendingClickCancelled = YES;
                return NO;
            }
            consume = YES; // Pair every swallowed down with a swallowed drag/up.
            if (hypot(location.x - _pendingClickLocation.x,
                      location.y - _pendingClickLocation.y) > 6) {
                _pendingClickCancelled = YES;
            }
            if (up) {
                for (NSInteger i = 0; i < _deviceCount; i++) {
                    GPTrackedDevice *tracked = &_devices[i];
                    if (tracked->device != _pendingClickDevice) continue;
                    // Fingers must still be resting at release. A light tap/lift cannot fire.
                    if (!_pendingClickCancelled && now - _pendingClickTime <= 1.0 &&
                        _running && tracked->running &&
                        [self deviceKindEnabledLocked:tracked->kind] &&
                        GPClickChordIsStationary(&tracked->clickChord, now) &&
                        target == _pendingClickTarget) {
                        *detectedDevice = tracked->kind;
                    }
                    break;
                }
                _pendingClickButton = -1;
                _pendingClickDevice = NULL;
            }
        } else if (down && _running) {
            GPTrackedDevice *candidate = NULL;
            NSInteger activeDevices = 0;
            for (NSInteger i = 0; i < _deviceCount; i++) {
                GPTrackedDevice *tracked = &_devices[i];
                if (!tracked->running || ![self deviceKindEnabledLocked:tracked->kind]) continue;
                if (tracked->clickChord.count > 0 && now - tracked->clickChord.lastFrame <= 0.25) {
                    activeDevices += 1;
                }
                BOOL enabled = tracked->kind == GPInputDeviceKindMagicMouse
                    ? _mouseClickEnabled : _trackpadClickEnabled;
                if (enabled && GPClickChordCanBegin(&tracked->clickChord, now) &&
                    tracked->recognitionState != GPRecognitionStateTriggered) candidate = tracked;
            }
            // Do not guess which device clicked if both touch surfaces are in use.
            if (candidate && activeDevices == 1) {
                candidate->clickChord.claimed = YES;
                candidate->recognitionState = GPRecognitionStateCancelled;
                _pendingClickButton = button;
                _pendingClickDevice = candidate->device;
                _pendingClickLocation = location;
                _pendingClickTime = now;
                _pendingClickTarget = target;
                _pendingClickCancelled = NO;
                consume = YES;
            }
        }
    }
    return consume;
}

- (void)setMinimumDistance:(CGFloat)minimumDistance
                 forDevice:(GPInputDeviceKind)deviceKind {
    @synchronized (self) {
        CGFloat clamped = MIN(MAX(minimumDistance, 0.03), 0.16);
        if (deviceKind == GPInputDeviceKindMagicMouse) {
            _mouseMinimumDistance = clamped;
        } else {
            _trackpadMinimumDistance = clamped;
        }
    }
}

- (void)setTrackpadFingerCount:(NSInteger)fingerCount {
    @synchronized (self) {
        _trackpadFingerCount = fingerCount == 3 ? 3 : 4;
        for (NSInteger index = 0; index < _deviceCount; index++) {
            _devices[index].recognitionState = GPRecognitionStateIdle;
        }
    }
}

- (void)setEnabled:(BOOL)enabled forDevice:(GPInputDeviceKind)deviceKind {
    @synchronized (self) {
        if (deviceKind == GPInputDeviceKindMagicMouse) {
            _mouseEnabled = enabled;
        } else {
            _trackpadEnabled = enabled;
        }
    }
}

- (void)processTouches:(MTTouch *)touches
                 count:(int32_t)touchCount
                device:(void *)device {
    CGFloat sumX = 0;
    CGFloat sumY = 0;
    NSInteger activeFingerCount = 0;
    GPClickContact clickContacts[3] = {0};
    GPInputDeviceKind deviceKind = GPInputDeviceKindUnknown;

    @synchronized (self) {
        for (NSInteger index = 0; index < _deviceCount; index++) {
            if (_devices[index].device == device) {
                deviceKind = _devices[index].kind;
                break;
            }
        }
    }
    if (deviceKind == GPInputDeviceKindUnknown) return;

    for (int32_t index = 0; index < touchCount; index++) {
        MTTouch touch = touches[index];
        BOOL activeState = touch.state == 3 || touch.state == 4;
        BOOL identifiedFinger = touch.fingerID >= 1 && touch.fingerID <= 5;
        BOOL identifiedHand = touch.handID == -1 || touch.handID == 1;
        BOOL usableContact = deviceKind == GPInputDeviceKindMagicMouse
            ? activeState
            : activeState && identifiedFinger && identifiedHand;

        if (usableContact) {
            if (activeFingerCount < 3) {
                clickContacts[activeFingerCount] = (GPClickContact){
                    .identifier = touch.pathIndex,
                    .position = CGPointMake(touch.normalizedVector.position.x,
                                            touch.normalizedVector.position.y),
                };
            }
            sumX += touch.normalizedVector.position.x;
            sumY += touch.normalizedVector.position.y;
            activeFingerCount += 1;
        }
    }

    GPSwipeDirection detectedDirection = GPSwipeDirectionDown;
    BOOL didDetect = NO;
    BOOL didBeginTracking = NO;
    NSInteger trackingFingerCount = 0;

    @synchronized (self) {
        if (!_running) return;
        GPTrackedDevice *tracked = NULL;
        for (NSInteger index = 0; index < _deviceCount; index++) {
            if (_devices[index].device == device) {
                tracked = &_devices[index];
                break;
            }
        }
        if (!tracked || !tracked->running || ![self deviceKindEnabledLocked:tracked->kind]) return;
        GPUpdateClickChord(&tracked->clickChord, clickContacts, activeFingerCount,
                           NSProcessInfo.processInfo.systemUptime);
        if (_pendingClickDevice == device &&
            !GPClickChordIsStationary(&tracked->clickChord, NSProcessInfo.processInfo.systemUptime)) {
            _pendingClickCancelled = YES;
        }

        NSInteger requiredFingerCount = tracked->kind == GPInputDeviceKindMagicMouse
            ? 3
            : _trackpadFingerCount;
        CGFloat minimumDistance = tracked->kind == GPInputDeviceKindMagicMouse
            ? _mouseMinimumDistance
            : _trackpadMinimumDistance;

        if (activeFingerCount == 0) {
            tracked->recognitionState = GPRecognitionStateIdle;
            return;
        }

        if (tracked->recognitionState == GPRecognitionStateIdle) {
            if (activeFingerCount == requiredFingerCount) {
                tracked->originX = sumX / requiredFingerCount;
                tracked->originY = sumY / requiredFingerCount;
                tracked->recognitionState = GPRecognitionStateTracking;
                didBeginTracking = YES;
                trackingFingerCount = requiredFingerCount;
            }
        } else if (tracked->recognitionState == GPRecognitionStateTracking) {
            if (activeFingerCount != requiredFingerCount) {
                tracked->recognitionState = GPRecognitionStateCancelled;
                return;
            }

            CGFloat centroidX = sumX / requiredFingerCount;
            CGFloat centroidY = sumY / requiredFingerCount;
            didDetect = GPClassifySwipe(
                centroidX - tracked->originX,
                centroidY - tracked->originY,
                minimumDistance,
                &detectedDirection
            );

            if (didDetect) {
                tracked->recognitionState = GPRecognitionStateTriggered;
            }
        }
    }

    if (didBeginTracking) {
        [self publishStatus:[NSString stringWithFormat:@"%@: %ld fingers detected — move together",
                                                        GPDeviceName(deviceKind),
                                                        (long)trackingFingerCount]];
    }

    if (didDetect) {
        GPSwipeDirection direction = detectedDirection;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate detectorDidRecognizeDirection:direction fromDevice:deviceKind];
        });
    }
}

- (void)publishStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"GesturePilot: %@", status);
        [NSUserDefaults.standardUserDefaults setObject:status forKey:@"gesturePilot.lastStatus"];
        [self.delegate detectorStatusDidChange:status];
    });
}

- (BOOL)runClickSelfTests {
    // Deterministic contact/button streams. No events are posted and no app is closed.
    GPClickContact contacts[3] = {
        {1, {0.3, 0.5}}, {2, {0.5, 0.5}}, {3, {0.7, 0.5}},
    };
    BOOL success = YES;
    for (NSInteger kind = GPInputDeviceKindTrackpad; kind <= GPInputDeviceKindMagicMouse; kind++) {
        for (NSInteger scenario = 0; scenario < 11; scenario++) {
            memset(_devices, 0, sizeof(_devices));
            _deviceCount = 1;
            _running = YES;
            _trackpadEnabled = _mouseEnabled = YES;
            _trackpadClickEnabled = _mouseClickEnabled = scenario != 5;
            _pendingClickButton = -1;
            _pendingClickDevice = NULL;
            _devices[0].device = (void *)(uintptr_t)1;
            _devices[0].kind = (GPInputDeviceKind)kind;
            _devices[0].running = YES;
            GPClickChord *chord = &_devices[0].clickChord;
            NSInteger count = scenario == 1 ? 1 : (scenario == 2 ? 2 : 3);
            GPUpdateClickChord(chord, contacts, count, 10.0);
            GPUpdateClickChord(chord, contacts, count, 10.12);
            if (scenario == 3) { // Already swiped: no click action from the same touch sequence.
                _devices[0].recognitionState = GPRecognitionStateTriggered;
            }
            if (scenario == 4) chord->lastFrame = 9.0; // stale device frame
            if (scenario == 6) { // both devices touched: cannot safely attribute the button
                _deviceCount = 2;
                _devices[1] = _devices[0];
                _devices[1].device = (void *)(uintptr_t)2;
                _devices[1].kind = kind == GPInputDeviceKindTrackpad
                    ? GPInputDeviceKindMagicMouse : GPInputDeviceKindTrackpad;
            }
            GPInputDeviceKind detected = GPInputDeviceKindUnknown;
            NSInteger button = kind == GPInputDeviceKindTrackpad ? 1 : 0;
            BOOL downConsumed = [self consumeButton:button down:YES up:NO
                location:CGPointMake(100, 100) time:10.13 target:42 detectedDevice:&detected];
            BOOL shouldClaim = scenario == 0 || scenario >= 7;
            success &= downConsumed == shouldClaim && detected == GPInputDeviceKindUnknown;
            if (scenario == 7) { // drag is swallowed but must not close anything
                success &= [self consumeButton:button down:NO up:NO
                    location:CGPointMake(115, 100) time:10.15 target:42 detectedDevice:&detected];
            }
            if (scenario == 8) GPUpdateClickChord(chord, NULL, 0, 10.15); // tap/lift
            NSTimeInterval releaseTime = scenario == 9 ? 11.3 : 10.18; // long hold
            pid_t target = scenario == 10 ? 43 : 42; // foreground app changed
            BOOL upConsumed = [self consumeButton:button down:NO up:YES
                location:CGPointMake(100, 100) time:releaseTime target:target detectedDevice:&detected];
            success &= upConsumed == shouldClaim;
            success &= detected == (scenario == 0 ? kind : GPInputDeviceKindUnknown);
            if (scenario == 0) {
                // Holding the same three fingers down cannot repeatedly close windows.
                success &= ![self consumeButton:button down:YES up:NO
                    location:CGPointMake(100, 100) time:10.2 target:42 detectedDevice:&detected];
            }
        }
    }
    memset(_devices, 0, sizeof(_devices));
    _deviceCount = 0;
    _running = NO;
    _pendingClickButton = -1;
    _pendingClickDevice = NULL;
    fprintf(stdout, "Click button routing (22 scenarios): %s\n", success ? "PASS" : "FAIL");
    return success;
}

- (BOOL)runDeviceShutdownSelfTest {
    // Simulate MTDeviceStop waiting for a callback that needs the detector lock.
    _deviceCount = 1;
    _running = YES;
    _devices[0].device = (__bridge void *)self;
    _devices[0].running = YES;
    _stopDevice = GPTestStopDevice;
    _releaseDevice = GPTestReleaseDevice;
    [self releaseDevices];
    BOOL success = GPTestStopCompleted && !_running && _deviceCount == 0;
    fprintf(stdout, "Device shutdown with in-flight callback: %s\n", success ? "PASS" : "FAIL");
    return success;
}

@end

#pragma mark - Window actions

@interface GPWindowActions : NSObject
@property(nonatomic, strong) NSMutableArray *minimizedWindows;
- (BOOL)isAccessibilityTrustedPrompting:(BOOL)prompt;
- (NSInteger)performAction:(GPGestureAction)action;
- (NSInteger)minimizeAllWindows;
- (NSInteger)restoreWindows;
- (NSInteger)minimizeCurrentWindow;
- (NSInteger)maximizeCurrentWindow;
- (NSInteger)closeCurrentWindow;
- (NSInteger)quitCurrentApplication;
- (void)openAccessibilitySettings;
@end

@implementation GPWindowActions

- (instancetype)init {
    self = [super init];
    if (self) {
        _minimizedWindows = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isAccessibilityTrustedPrompting:(BOOL)prompt {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @(prompt)};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

- (NSInteger)performAction:(GPGestureAction)action {
    if (action == GPGestureActionNone) return 0;
    if (![self isAccessibilityTrustedPrompting:YES]) {
        NSBeep();
        return 0;
    }

    switch (action) {
        case GPGestureActionNone: return 0;
        case GPGestureActionMinimizeAll: return [self minimizeAllWindows];
        case GPGestureActionRestore: return [self restoreWindows];
        case GPGestureActionToggle:
            return self.minimizedWindows.count > 0
                ? [self restoreWindows]
                : [self minimizeAllWindows];
        case GPGestureActionMinimizeCurrent: return [self minimizeCurrentWindow];
        case GPGestureActionMaximizeCurrent: return [self maximizeCurrentWindow];
        case GPGestureActionCloseCurrent: return [self closeCurrentWindow];
        case GPGestureActionQuitCurrent: return [self quitCurrentApplication];
        // These actions use the asynchronous GPLaunchOverview path.
        case GPGestureActionMissionControl:
        case GPGestureActionAppExpose: return 0;
    }
}

- (NSArray *)windowsForApplication:(AXUIElementRef)application {
    CFTypeRef value = NULL;
    AXError result = AXUIElementCopyAttributeValue(
        application,
        kAXWindowsAttribute,
        &value
    );
    if (result != kAXErrorSuccess || !value) return @[];
    return CFBridgingRelease(value);
}

- (BOOL)isWindowMinimized:(AXUIElementRef)window {
    CFTypeRef value = NULL;
    AXError result = AXUIElementCopyAttributeValue(
        window,
        kAXMinimizedAttribute,
        &value
    );
    if (result != kAXErrorSuccess || !value) return NO;

    BOOL minimized = CFGetTypeID(value) == CFBooleanGetTypeID()
        ? CFBooleanGetValue(value)
        : NO;
    CFRelease(value);
    return minimized;
}

- (BOOL)isWindowMinimizable:(AXUIElementRef)window {
    Boolean settable = false;
    return AXUIElementIsAttributeSettable(
        window,
        kAXMinimizedAttribute,
        &settable
    ) == kAXErrorSuccess && settable;
}

- (BOOL)booleanAttribute:(CFStringRef)attribute
                element:(AXUIElementRef)element {
    CFTypeRef value = NULL;
    AXError result = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (result != kAXErrorSuccess || !value) return NO;
    BOOL booleanValue = CFGetTypeID(value) == CFBooleanGetTypeID()
        ? CFBooleanGetValue(value)
        : NO;
    CFRelease(value);
    return booleanValue;
}

- (AXUIElementRef)copyWindowAttribute:(CFStringRef)attribute
                        application:(AXUIElementRef)application {
    CFTypeRef windowValue = NULL;
    AXError result = AXUIElementCopyAttributeValue(application, attribute, &windowValue);
    return result == kAXErrorSuccess && windowValue
        ? (AXUIElementRef)windowValue
        : NULL;
}

- (AXUIElementRef)copyCurrentWindow {
    NSRunningApplication *frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
    return [self copyCurrentWindowForApplication:frontmost];
}

- (AXUIElementRef)copyCurrentWindowForApplication:(NSRunningApplication *)frontmost {
    if (!frontmost || frontmost.terminated) return NULL;

    AXUIElementRef application = AXUIElementCreateApplication(frontmost.processIdentifier);
    AXUIElementRef window = [self copyWindowAttribute:kAXFocusedWindowAttribute
                                         application:application];
    if (!window) {
        window = [self copyWindowAttribute:kAXMainWindowAttribute
                               application:application];
    }

    if (!window) {
        NSArray *windows = [self windowsForApplication:application];
        AXUIElementRef candidate = NULL;

        for (id windowObject in windows) {
            AXUIElementRef item = (__bridge AXUIElementRef)windowObject;
            if ([self booleanAttribute:kAXFocusedAttribute element:item] ||
                [self booleanAttribute:kAXMainAttribute element:item]) {
                candidate = item;
                break;
            }
        }

        if (!candidate) {
            for (id windowObject in windows) {
                AXUIElementRef item = (__bridge AXUIElementRef)windowObject;
                if (![self isWindowMinimized:item]) {
                    candidate = item;
                    break;
                }
            }
        }

        if (candidate) {
            CFRetain(candidate);
            window = candidate;
        }
    }

    NSLog(@"GesturePilot: current window lookup app=%@ pid=%d result=%@",
          frontmost.bundleIdentifier ?: frontmost.localizedName ?: @"unknown",
          frontmost.processIdentifier,
          window ? @"found" : @"missing");
    CFRelease(application);
    return window;
}

- (BOOL)pressWindowButton:(CFStringRef)buttonAttribute
                   window:(AXUIElementRef)window {
    CFTypeRef buttonValue = NULL;
    AXError copyResult = AXUIElementCopyAttributeValue(
        window,
        buttonAttribute,
        &buttonValue
    );
    if (copyResult != kAXErrorSuccess || !buttonValue) return NO;

    AXError pressResult = AXUIElementPerformAction(
        (AXUIElementRef)buttonValue,
        kAXPressAction
    );
    CFRelease(buttonValue);
    return pressResult == kAXErrorSuccess;
}

- (BOOL)minimizeWindow:(AXUIElementRef)window {
    if ([self isWindowMinimized:window]) return NO;

    AXError setResult = AXUIElementSetAttributeValue(
        window,
        kAXMinimizedAttribute,
        kCFBooleanTrue
    );
    if (setResult == kAXErrorSuccess) return YES;

    BOOL pressed = [self pressWindowButton:kAXMinimizeButtonAttribute window:window];
    NSLog(@"GesturePilot: direct minimize failed (%d), button fallback=%@",
          setResult,
          pressed ? @"success" : @"failed");
    return pressed;
}

- (void)trackMinimizedWindow:(AXUIElementRef)window {
    for (id windowObject in self.minimizedWindows) {
        AXUIElementRef trackedWindow = (__bridge AXUIElementRef)windowObject;
        if (CFEqual(trackedWindow, window)) return;
    }
    [self.minimizedWindows addObject:(__bridge id)window];
}

- (NSInteger)minimizeCurrentWindow {
    AXUIElementRef window = [self copyCurrentWindow];
    if (!window) return 0;

    BOOL minimized = [self minimizeWindow:window];
    if (minimized) [self trackMinimizedWindow:window];
    NSInteger affected = minimized ? 1 : 0;
    CFRelease(window);
    return affected;
}

- (NSInteger)closeCurrentWindow {
    AXUIElementRef window = [self copyCurrentWindow];
    if (!window) return 0;
    // Press the normal close button so the application can ask about unsaved work.
    BOOL requested = [self pressWindowButton:kAXCloseButtonAttribute window:window];
    CFRelease(window);
    return requested ? 1 : 0;
}

- (NSInteger)quitCurrentApplication {
    NSRunningApplication *application = NSWorkspace.sharedWorkspace.frontmostApplication;
    return [self requestQuitApplication:application];
}

- (NSInteger)requestQuitApplication:(NSRunningApplication *)application {
    if (!application || application.terminated ||
        application.activationPolicy != NSApplicationActivationPolicyRegular) return 0;
    // A normal quit request lets the application save or cancel. Never force-quit.
    return [application terminate] ? 1 : 0;
}

- (NSScreen *)screenForAXWindowPosition:(CGPoint)position size:(CGSize)size {
    NSScreen *primaryScreen = NSScreen.screens.firstObject ?: NSScreen.mainScreen;
    if (!primaryScreen) return nil;

    CGFloat primaryTop = NSMaxY(primaryScreen.frame);
    NSPoint cocoaCenter = NSMakePoint(
        position.x + size.width / 2.0,
        primaryTop - (position.y + size.height / 2.0)
    );
    for (NSScreen *screen in NSScreen.screens) {
        if (NSPointInRect(cocoaCenter, screen.frame)) return screen;
    }
    return NSScreen.mainScreen ?: primaryScreen;
}

- (BOOL)pressZoomButtonForWindow:(AXUIElementRef)window {
    return [self pressWindowButton:kAXZoomButtonAttribute window:window];
}

- (NSInteger)maximizeCurrentWindow {
    AXUIElementRef window = [self copyCurrentWindow];
    if (!window) return 0;

    CFTypeRef positionValue = NULL;
    CFTypeRef sizeValue = NULL;
    CGPoint position = CGPointZero;
    CGSize size = CGSizeZero;
    BOOL hasFrame = AXUIElementCopyAttributeValue(
        window,
        kAXPositionAttribute,
        &positionValue
    ) == kAXErrorSuccess &&
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &sizeValue) == kAXErrorSuccess &&
        positionValue && sizeValue &&
        CFGetTypeID(positionValue) == AXValueGetTypeID() &&
        CFGetTypeID(sizeValue) == AXValueGetTypeID() &&
        AXValueGetValue((AXValueRef)positionValue, kAXValueCGPointType, &position) &&
        AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size);

    BOOL maximized = NO;
    if (hasFrame) {
        NSScreen *screen = [self screenForAXWindowPosition:position size:size];
        NSScreen *primaryScreen = NSScreen.screens.firstObject ?: NSScreen.mainScreen;
        if (screen && primaryScreen) {
            NSRect visibleFrame = screen.visibleFrame;
            CGPoint targetPosition = CGPointMake(
                NSMinX(visibleFrame),
                NSMaxY(primaryScreen.frame) - NSMaxY(visibleFrame)
            );
            CGSize targetSize = visibleFrame.size;

            AXValueRef targetPositionValue = AXValueCreate(
                kAXValueCGPointType,
                &targetPosition
            );
            AXValueRef targetSizeValue = AXValueCreate(kAXValueCGSizeType, &targetSize);
            AXError positionResult = AXUIElementSetAttributeValue(
                window,
                kAXPositionAttribute,
                targetPositionValue
            );
            AXError sizeResult = AXUIElementSetAttributeValue(
                window,
                kAXSizeAttribute,
                targetSizeValue
            );
            CFRelease(targetPositionValue);
            CFRelease(targetSizeValue);
            maximized = positionResult == kAXErrorSuccess && sizeResult == kAXErrorSuccess;
        }
    }

    if (positionValue) CFRelease(positionValue);
    if (sizeValue) CFRelease(sizeValue);
    if (!maximized) maximized = [self pressZoomButtonForWindow:window];
    CFRelease(window);
    return maximized ? 1 : 0;
}

- (NSInteger)minimizeAllWindows {
    NSInteger minimizedCount = 0;

    for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
        if (application.terminated || application.activationPolicy != NSApplicationActivationPolicyRegular) {
            continue;
        }

        AXUIElementRef applicationElement = AXUIElementCreateApplication(application.processIdentifier);
        NSArray *windows = [self windowsForApplication:applicationElement];

        for (id windowObject in windows) {
            AXUIElementRef window = (__bridge AXUIElementRef)windowObject;
            if ([self minimizeWindow:window]) {
                [self trackMinimizedWindow:window];
                minimizedCount += 1;
            }
        }

        CFRelease(applicationElement);
    }

    return minimizedCount;
}

- (NSInteger)restoreWindows {
    NSInteger restoredCount = 0;
    NSArray *trackedWindows = [self.minimizedWindows copy];
    [self.minimizedWindows removeAllObjects];

    for (id windowObject in trackedWindows) {
        AXUIElementRef window = (__bridge AXUIElementRef)windowObject;
        AXError result = AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute,
            kCFBooleanFalse
        );
        if (result == kAXErrorSuccess) {
            restoredCount += 1;
        } else if ([self isWindowMinimized:window]) {
            [self trackMinimizedWindow:window];
            NSLog(@"GesturePilot: restore failed (%d); keeping window for retry", result);
        }
    }
    return restoredCount;
}

- (void)openAccessibilitySettings {
    NSURL *url = [NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
}

@end

#pragma mark - Application

@interface GPAppDelegate : NSObject <NSApplicationDelegate, GPMultitouchDetectorDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *enabledMenuItem;
@property(nonatomic, strong) NSMenuItem *mouseEnabledMenuItem;
@property(nonatomic, strong) NSMenuItem *statusMenuItem;
@property(nonatomic, strong) NSMenuItem *mappingMenuItem;
@property(nonatomic, strong) NSWindow *settingsWindow;
@property(nonatomic, strong) NSTextField *engineStatusLabel;
@property(nonatomic, strong) NSTextField *permissionLabel;
@property(nonatomic, strong) NSTextField *sensitivityLabel;
@property(nonatomic, strong) NSTextField *settingsTitleLabel;
@property(nonatomic, strong) NSTextField *introLabel;
@property(nonatomic, strong) NSTextField *conflictLabel;
@property(nonatomic, strong) NSTextField *fingerCountTitleLabel;
@property(nonatomic, strong) NSTextField *deviceHintLabel;
@property(nonatomic, strong) NSButton *enabledButton;
@property(nonatomic, strong) NSButton *launchAtLoginButton;
@property(nonatomic, strong) NSButton *inputSettingsButton;
@property(nonatomic, strong) NSSlider *sensitivitySlider;
@property(nonatomic, strong) NSSegmentedControl *inputDeviceControl;
@property(nonatomic, strong) NSSegmentedControl *fingerCountControl;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSPopUpButton *> *mappingPopups;
@property(nonatomic, strong) NSPopUpButton *clickMappingPopup;
@property(nonatomic, strong) GPMultitouchDetector *detector;
@property(nonatomic, strong) GPWindowActions *windowActions;
@property(nonatomic) NSUInteger detectorRecoveryGeneration;
@end

@implementation GPAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        GPEnabledKey: @YES,
        GPSensitivityKey: @0.075,
        GPFingerCountKey: @4,
        GPActionKey(GPSwipeDirectionUp): @(GPGestureActionRestore),
        GPActionKey(GPSwipeDirectionDown): @(GPGestureActionMinimizeAll),
        GPActionKey(GPSwipeDirectionLeft): @(GPGestureActionNone),
        GPActionKey(GPSwipeDirectionRight): @(GPGestureActionNone),
        GPMouseEnabledKey: @YES,
        GPMouseSensitivityKey: @0.055,
        GPMouseActionKey(GPSwipeDirectionUp): @(GPGestureActionMaximizeCurrent),
        GPMouseActionKey(GPSwipeDirectionDown): @(GPGestureActionMinimizeCurrent),
        GPMouseActionKey(GPSwipeDirectionLeft): @(GPGestureActionNone),
        GPMouseActionKey(GPSwipeDirectionRight): @(GPGestureActionNone),
        GPClickActionKey(GPInputDeviceKindTrackpad): @(GPGestureActionNone),
        GPClickActionKey(GPInputDeviceKindMagicMouse): @(GPGestureActionNone),
    }];

    self.windowActions = [[GPWindowActions alloc] init];
    self.detector = [[GPMultitouchDetector alloc] init];
    self.detector.delegate = self;
    [self.detector setMinimumDistance:[self sensitivityForDevice:GPInputDeviceKindTrackpad]
                           forDevice:GPInputDeviceKindTrackpad];
    [self.detector setMinimumDistance:[self sensitivityForDevice:GPInputDeviceKindMagicMouse]
                           forDevice:GPInputDeviceKindMagicMouse];
    [self.detector setTrackpadFingerCount:[self fingerCount]];
    [self.detector setEnabled:[self gesturesEnabledForDevice:GPInputDeviceKindTrackpad]
                    forDevice:GPInputDeviceKindTrackpad];
    [self.detector setEnabled:[self gesturesEnabledForDevice:GPInputDeviceKindMagicMouse]
                    forDevice:GPInputDeviceKindMagicMouse];
    [self.detector setClickEnabled:[self clickActionForDevice:GPInputDeviceKindTrackpad] != GPGestureActionNone
                         forDevice:GPInputDeviceKindTrackpad];
    [self.detector setClickEnabled:[self clickActionForDevice:GPInputDeviceKindMagicMouse] != GPGestureActionNone
                         forDevice:GPInputDeviceKindMagicMouse];

    [self buildSettingsWindow];
    [self buildStatusItem];

    if ([self anyGesturesEnabled]) {
        [self.detector start];
    } else {
        [self detectorStatusDidChange:@"Gestures disabled"];
    }

    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserver:self
        selector:@selector(workspaceWillSleep:)
        name:NSWorkspaceWillSleepNotification
        object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserver:self
        selector:@selector(workspaceDidWake:)
        name:NSWorkspaceDidWakeNotification
        object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserver:self
        selector:@selector(workspaceDidWake:)
        name:NSWorkspaceScreensDidWakeNotification
        object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserver:self
        selector:@selector(workspaceDidWake:)
        name:NSWorkspaceSessionDidBecomeActiveNotification
        object:nil];

    BOOL firstLaunch = ![NSUserDefaults.standardUserDefaults boolForKey:GPWelcomeKey];
    [self showSettings:nil];

    if (firstLaunch) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:GPWelcomeKey];
    }

    if (![self.windowActions isAccessibilityTrustedPrompting:NO]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self.windowActions isAccessibilityTrustedPrompting:YES];
            [self refreshSettingsControls];
        });
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender
                    hasVisibleWindows:(BOOL)hasVisibleWindows {
    NSLog(@"GesturePilot: Reopen requested");
    [self showSettings:nil];
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.detector stop];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

- (BOOL)gesturesEnabled {
    return [self gesturesEnabledForDevice:GPInputDeviceKindTrackpad];
}

- (BOOL)gesturesEnabledForDevice:(GPInputDeviceKind)deviceKind {
    NSString *key = deviceKind == GPInputDeviceKindMagicMouse
        ? GPMouseEnabledKey
        : GPEnabledKey;
    return [NSUserDefaults.standardUserDefaults boolForKey:key];
}

- (BOOL)anyGesturesEnabled {
    return [self gesturesEnabledForDevice:GPInputDeviceKindTrackpad] ||
        [self gesturesEnabledForDevice:GPInputDeviceKindMagicMouse];
}

- (CGFloat)sensitivity {
    return [self sensitivityForDevice:GPInputDeviceKindTrackpad];
}

- (CGFloat)sensitivityForDevice:(GPInputDeviceKind)deviceKind {
    NSString *key = deviceKind == GPInputDeviceKindMagicMouse
        ? GPMouseSensitivityKey
        : GPSensitivityKey;
    double value = [NSUserDefaults.standardUserDefaults doubleForKey:key];
    return MIN(MAX(value, deviceKind == GPInputDeviceKindMagicMouse ? 0.03 : 0.04), 0.16);
}

- (NSInteger)fingerCount {
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:GPFingerCountKey];
    return value == 3 ? 3 : 4;
}

- (GPGestureAction)actionForDirection:(GPSwipeDirection)direction {
    return [self actionForDirection:direction device:GPInputDeviceKindTrackpad];
}

- (GPGestureAction)clickActionForDevice:(GPInputDeviceKind)deviceKind {
    NSInteger action = [NSUserDefaults.standardUserDefaults integerForKey:GPClickActionKey(deviceKind)];
    return action >= GPGestureActionNone && action <= GPGestureActionQuitCurrent
        ? (GPGestureAction)action : GPGestureActionNone;
}

- (GPGestureAction)actionForDirection:(GPSwipeDirection)direction
                               device:(GPInputDeviceKind)deviceKind {
    return (GPGestureAction)[NSUserDefaults.standardUserDefaults
        integerForKey:GPActionKeyForDevice(deviceKind, direction)];
}

- (GPInputDeviceKind)selectedDeviceKind {
    return self.inputDeviceControl.selectedSegment == 1
        ? GPInputDeviceKindMagicMouse
        : GPInputDeviceKindTrackpad;
}

- (void)workspaceWillSleep:(NSNotification *)notification {
    self.detectorRecoveryGeneration += 1;
    [self.detector stop];
}

- (BOOL)detectorHasAllEnabledDevices {
    BOOL trackpadReady = ![self gesturesEnabledForDevice:GPInputDeviceKindTrackpad] ||
        [self.detector isRunningForDevice:GPInputDeviceKindTrackpad];
    BOOL mouseReady = ![self gesturesEnabledForDevice:GPInputDeviceKindMagicMouse] ||
        [self.detector isRunningForDevice:GPInputDeviceKindMagicMouse];
    BOOL clicksRequired =
        ([self gesturesEnabledForDevice:GPInputDeviceKindTrackpad] &&
         [self clickActionForDevice:GPInputDeviceKindTrackpad] != GPGestureActionNone) ||
        ([self gesturesEnabledForDevice:GPInputDeviceKindMagicMouse] &&
         [self clickActionForDevice:GPInputDeviceKindMagicMouse] != GPGestureActionNone);
    return trackpadReady && mouseReady &&
        (!clicksRequired || [self.detector isClickMonitoringReady]);
}

- (void)configureDetectorFromSettings {
    [self.detector setMinimumDistance:[self sensitivityForDevice:GPInputDeviceKindTrackpad]
                           forDevice:GPInputDeviceKindTrackpad];
    [self.detector setMinimumDistance:[self sensitivityForDevice:GPInputDeviceKindMagicMouse]
                           forDevice:GPInputDeviceKindMagicMouse];
    [self.detector setTrackpadFingerCount:[self fingerCount]];
    [self.detector setEnabled:[self gesturesEnabledForDevice:GPInputDeviceKindTrackpad]
                    forDevice:GPInputDeviceKindTrackpad];
    [self.detector setEnabled:[self gesturesEnabledForDevice:GPInputDeviceKindMagicMouse]
                    forDevice:GPInputDeviceKindMagicMouse];
    [self.detector setClickEnabled:[self clickActionForDevice:GPInputDeviceKindTrackpad] != GPGestureActionNone
                         forDevice:GPInputDeviceKindTrackpad];
    [self.detector setClickEnabled:[self clickActionForDevice:GPInputDeviceKindMagicMouse] != GPGestureActionNone
                         forDevice:GPInputDeviceKindMagicMouse];
}

- (void)workspaceDidWake:(NSNotification *)notification {
    if (![self anyGesturesEnabled]) return;

    self.detectorRecoveryGeneration += 1;
    NSUInteger generation = self.detectorRecoveryGeneration;
    [self detectorStatusDidChange:@"Resuming gesture recognition…"];

    for (NSNumber *delayValue in @[@0.75, @2.5, @6.0]) {
        NSTimeInterval delay = delayValue.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation != self.detectorRecoveryGeneration ||
                ![self anyGesturesEnabled]) {
                return;
            }

            [self configureDetectorFromSettings];
            [self.detector stop];
            [self.detector start];
            if ([self detectorHasAllEnabledDevices]) {
                self.detectorRecoveryGeneration += 1;
            }
        });
    }
}

- (void)detectorDidRecognizeDirection:(GPSwipeDirection)direction
                           fromDevice:(GPInputDeviceKind)deviceKind {
    if (![self gesturesEnabledForDevice:deviceKind]) return;
    GPGestureAction action = [self actionForDirection:direction device:deviceKind];
    [self performGestureAction:action name:GPDirectionName(direction) device:deviceKind];
}

- (void)detectorDidRecognizeThreeFingerClickFromDevice:(GPInputDeviceKind)deviceKind {
    if (![self gesturesEnabledForDevice:deviceKind]) return;
    [self performGestureAction:[self clickActionForDevice:deviceKind]
                          name:@"3-Finger Click" device:deviceKind];
}

- (void)performGestureAction:(GPGestureAction)action name:(NSString *)name
                      device:(GPInputDeviceKind)deviceKind {
    if (action == GPGestureActionNone) {
        [self detectorStatusDidChange:[NSString stringWithFormat:@"%@ %@ detected — no action assigned",
                                      GPDeviceName(deviceKind),
                                      name]];
        return;
    }

    if (GPIsOverviewAction(action)) {
        NSString *prefix = [NSString stringWithFormat:@"%@ %@: %@",
                            GPDeviceName(deviceKind), name, GPActionName(action)];
        [self detectorStatusDidChange:[prefix stringByAppendingString:@" — requesting…"]];
        GPLaunchOverview(action, ^(NSError *error) {
            NSString *result = error
                ? [NSString stringWithFormat:@"could not open (%@)", error.localizedDescription]
                : @"requested";
            [self detectorStatusDidChange:[NSString stringWithFormat:@"%@ — %@", prefix, result]];
            if (error) NSLog(@"GesturePilot: overview launch failed: %@", error);
        });
        return;
    }

    NSInteger affected = [self.windowActions performAction:action];
    if (action == GPGestureActionCloseCurrent || action == GPGestureActionQuitCurrent) {
        [self detectorStatusDidChange:[NSString stringWithFormat:@"%@ %@: %@ — %@",
            GPDeviceName(deviceKind), name, GPActionName(action),
            affected ? @"requested" : @"could not request"]];
        return;
    }
    [self detectorStatusDidChange:[NSString stringWithFormat:@"%@ %@: %@ (%ld)",
                                   GPDeviceName(deviceKind),
                                   name,
                                   GPActionName(action),
                                   (long)affected]];
    self.statusItem.button.contentTintColor = NSColor.systemGreenColor;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.statusItem.button.contentTintColor = nil;
    });
}

- (void)detectorStatusDidChange:(NSString *)status {
    [NSUserDefaults.standardUserDefaults setObject:status forKey:@"gesturePilot.lastStatus"];
    self.statusMenuItem.title = status;
    self.engineStatusLabel.stringValue = status;
}

- (void)buildStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:28.0];
    self.statusItem.autosaveName = @"GesturePilot.MainStatusItem";
    NSImage *menuIcon = [NSImage
        imageWithSystemSymbolName:@"hand.raised.fill"
        accessibilityDescription:@"GesturePilot"];
    NSImageSymbolConfiguration *menuConfiguration = [NSImageSymbolConfiguration
        configurationWithPointSize:16
        weight:NSFontWeightSemibold];
    menuIcon = [menuIcon imageWithSymbolConfiguration:menuConfiguration];

    if (menuIcon) {
        menuIcon.template = YES;
        self.statusItem.button.image = menuIcon;
        self.statusItem.button.imagePosition = NSImageOnly;
        self.statusItem.button.imageScaling = NSImageScaleProportionallyDown;
    } else {
        self.statusItem.button.title = @"✋︎";
        self.statusItem.button.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    }
    self.statusItem.button.toolTip = @"GesturePilot";
    self.statusItem.visible = YES;
    NSString *menuDiagnostic = [NSString stringWithFormat:
        @"Menu item created (symbol=%@, visible=%@, width=%.0f)",
        menuIcon ? @"yes" : @"fallback",
        self.statusItem.visible ? @"yes" : @"no",
        self.statusItem.length];
    [NSUserDefaults.standardUserDefaults setObject:menuDiagnostic
                                            forKey:@"gesturePilot.menuDiagnostic"];
    NSLog(@"GesturePilot: Menu item created (symbol=%@, visible=%@, width=%.0f)",
          menuIcon ? @"yes" : @"fallback",
          self.statusItem.visible ? @"yes" : @"no",
          self.statusItem.length);

    NSMenu *menu = [[NSMenu alloc] init];
    self.enabledMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Enable Trackpad Gestures"
        action:@selector(toggleEnabled:)
        keyEquivalent:@""];
    self.enabledMenuItem.target = self;
    self.enabledMenuItem.state = [self gesturesEnabledForDevice:GPInputDeviceKindTrackpad]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    [menu addItem:self.enabledMenuItem];

    self.mouseEnabledMenuItem = [[NSMenuItem alloc]
        initWithTitle:@"Enable Magic Mouse Gestures"
        action:@selector(toggleMouseEnabled:)
        keyEquivalent:@""];
    self.mouseEnabledMenuItem.target = self;
    self.mouseEnabledMenuItem.state = [self gesturesEnabledForDevice:GPInputDeviceKindMagicMouse]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    [menu addItem:self.mouseEnabledMenuItem];

    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Starting…" action:nil keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];
    [menu addItem:NSMenuItem.separatorItem];

    self.mappingMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.mappingMenuItem.enabled = NO;
    [menu addItem:self.mappingMenuItem];
    [self updateMappingSummary];

    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *settings = [[NSMenuItem alloc]
        initWithTitle:@"Settings…"
        action:@selector(showSettings:)
        keyEquivalent:@","];
    settings.target = self;
    [menu addItem:settings];

    NSMenuItem *permissions = [[NSMenuItem alloc]
        initWithTitle:@"Accessibility Permission…"
        action:@selector(openAccessibilitySettings:)
        keyEquivalent:@""];
    permissions.target = self;
    [menu addItem:permissions];

    NSMenuItem *restore = [[NSMenuItem alloc]
        initWithTitle:@"Restore Windows"
        action:@selector(restoreWindows:)
        keyEquivalent:@""];
    restore.target = self;
    [menu addItem:restore];

    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"Quit GesturePilot"
        action:@selector(quit:)
        keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = frame;
    return label;
}

- (NSTextField *)wrappingLabelWithText:(NSString *)text frame:(NSRect)frame {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.frame = frame;
    label.maximumNumberOfLines = 0;
    return label;
}

- (NSButton *)buttonWithTitle:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    button.title = title;
    button.bezelStyle = NSBezelStyleRounded;
    button.target = self;
    button.action = action;
    return button;
}

- (void)buildSettingsWindow {
    self.settingsWindow = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 590, 740)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered
        defer:NO];
    self.settingsWindow.title = @"GesturePilot Settings";
    self.settingsWindow.releasedWhenClosed = NO;
    [self.settingsWindow center];

    NSView *content = self.settingsWindow.contentView;

    self.settingsTitleLabel = [self labelWithText:@"Gesture mappings"
                                            frame:NSMakeRect(24, 691, 500, 28)];
    self.settingsTitleLabel.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
    [content addSubview:self.settingsTitleLabel];

    self.introLabel = [self wrappingLabelWithText:@""
                                             frame:NSMakeRect(24, 644, 542, 40)];
    [content addSubview:self.introLabel];

    self.engineStatusLabel = [self labelWithText:@"Starting…"
                                           frame:NSMakeRect(24, 616, 542, 20)];
    self.engineStatusLabel.textColor = NSColor.secondaryLabelColor;
    self.engineStatusLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    [content addSubview:self.engineStatusLabel];

    NSTextField *inputDeviceTitle = [self labelWithText:@"Device"
                                                  frame:NSMakeRect(54, 575, 86, 22)];
    inputDeviceTitle.alignment = NSTextAlignmentRight;
    [content addSubview:inputDeviceTitle];

    self.inputDeviceControl = [NSSegmentedControl
        segmentedControlWithLabels:@[@"Trackpad", @"Magic Mouse"]
        trackingMode:NSSegmentSwitchTrackingSelectOne
        target:self
        action:@selector(inputDeviceChanged:)];
    self.inputDeviceControl.frame = NSMakeRect(155, 570, 290, 28);
    self.inputDeviceControl.selectedSegment = 0;
    [content addSubview:self.inputDeviceControl];

    self.fingerCountTitleLabel = [self labelWithText:@"Swipe fingers"
                                                frame:NSMakeRect(44, 531, 96, 22)];
    self.fingerCountTitleLabel.alignment = NSTextAlignmentRight;
    [content addSubview:self.fingerCountTitleLabel];

    self.fingerCountControl = [NSSegmentedControl
        segmentedControlWithLabels:@[@"3 Fingers", @"4 Fingers"]
        trackingMode:NSSegmentSwitchTrackingSelectOne
        target:self
        action:@selector(fingerCountChanged:)];
    self.fingerCountControl.frame = NSMakeRect(155, 526, 220, 28);
    [content addSubview:self.fingerCountControl];

    self.deviceHintLabel = [self labelWithText:@"Magic Mouse gestures use exactly 3 fingers."
                                         frame:NSMakeRect(155, 531, 320, 22)];
    self.deviceHintLabel.textColor = NSColor.secondaryLabelColor;
    self.deviceHintLabel.hidden = YES;
    [content addSubview:self.deviceHintLabel];

    self.enabledButton = [NSButton checkboxWithTitle:@"Enable gestures"
                                              target:self
                                              action:@selector(enabledChanged:)];
    self.enabledButton.frame = NSMakeRect(24, 490, 360, 24);
    [content addSubview:self.enabledButton];

    self.mappingPopups = [NSMutableDictionary dictionary];
    NSArray<NSString *> *actionNames = @[
        GPActionName(GPGestureActionNone),
        GPActionName(GPGestureActionMinimizeAll),
        GPActionName(GPGestureActionRestore),
        GPActionName(GPGestureActionToggle),
        GPActionName(GPGestureActionMinimizeCurrent),
        GPActionName(GPGestureActionMaximizeCurrent),
        GPActionName(GPGestureActionMissionControl),
        GPActionName(GPGestureActionAppExpose),
        GPActionName(GPGestureActionCloseCurrent),
        GPActionName(GPGestureActionQuitCurrent),
    ];

    CGFloat rowY = 449;
    for (NSInteger rawDirection = GPSwipeDirectionUp;
         rawDirection <= GPSwipeDirectionRight;
         rawDirection++) {
        GPSwipeDirection direction = (GPSwipeDirection)rawDirection;
        NSTextField *label = [self labelWithText:GPDirectionName(direction)
                                          frame:NSMakeRect(35, rowY + 4, 105, 22)];
        label.alignment = NSTextAlignmentRight;
        [content addSubview:label];

        NSPopUpButton *popup = [[NSPopUpButton alloc]
            initWithFrame:NSMakeRect(155, rowY, 290, 28)
            pullsDown:NO];
        [popup addItemsWithTitles:actionNames];
        popup.tag = rawDirection;
        popup.target = self;
        popup.action = @selector(mappingChanged:);
        self.mappingPopups[@(rawDirection)] = popup;
        [content addSubview:popup];
        rowY -= 38;
    }

    NSTextField *clickLabel = [self labelWithText:@"3-Finger Click"
                                           frame:NSMakeRect(24, 291, 116, 22)];
    clickLabel.alignment = NSTextAlignmentRight;
    [content addSubview:clickLabel];
    self.clickMappingPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(155, 287, 290, 28)
                                                     pullsDown:NO];
    [self.clickMappingPopup addItemsWithTitles:actionNames];
    self.clickMappingPopup.target = self;
    self.clickMappingPopup.action = @selector(clickMappingChanged:);
    [content addSubview:self.clickMappingPopup];
    NSTextField *clickHint = [self labelWithText:
        @"Rest 3 fingers, click and release, then lift. A light tap does nothing."
        frame:NSMakeRect(24, 262, 542, 20)];
    clickHint.font = [NSFont systemFontOfSize:11];
    clickHint.textColor = NSColor.secondaryLabelColor;
    [content addSubview:clickHint];
    NSTextField *sensitivityTitle = [self labelWithText:@"Sensitivity"
                                                  frame:NSMakeRect(54, 237, 86, 22)];
    sensitivityTitle.alignment = NSTextAlignmentRight;
    [content addSubview:sensitivityTitle];

    self.sensitivitySlider = [[NSSlider alloc]
        initWithFrame:NSMakeRect(155, 234, 255, 25)];
    self.sensitivitySlider.minValue = 0.03;
    self.sensitivitySlider.maxValue = 0.16;
    self.sensitivitySlider.continuous = YES;
    self.sensitivitySlider.target = self;
    self.sensitivitySlider.action = @selector(sensitivityChanged:);
    [content addSubview:self.sensitivitySlider];

    self.sensitivityLabel = [self labelWithText:@"Medium"
                                          frame:NSMakeRect(425, 237, 70, 22)];
    [content addSubview:self.sensitivityLabel];

    self.permissionLabel = [self labelWithText:@"Checking Accessibility…"
                                         frame:NSMakeRect(24, 192, 270, 22)];
    [content addSubview:self.permissionLabel];
    [content addSubview:[self buttonWithTitle:@"Grant Permission"
                                       action:@selector(requestAccessibility:)
                                       frame:NSMakeRect(302, 187, 125, 30)]];
    [content addSubview:[self buttonWithTitle:@"Open Settings"
                                      action:@selector(openAccessibilitySettings:)
                                       frame:NSMakeRect(435, 187, 115, 30)]];

    [content addSubview:[self buttonWithTitle:@"Test Minimize All"
                                      action:@selector(testMinimize:)
                                       frame:NSMakeRect(24, 145, 155, 32)]];
    [content addSubview:[self buttonWithTitle:@"Restore Test Windows"
                                      action:@selector(testRestore:)
                                       frame:NSMakeRect(189, 145, 175, 32)]];
    self.inputSettingsButton = [self buttonWithTitle:@"Input Settings"
                                               action:@selector(openInputSettings:)
                                                frame:NSMakeRect(374, 145, 150, 32)];
    [content addSubview:self.inputSettingsButton];

    self.launchAtLoginButton = [NSButton checkboxWithTitle:@"Launch GesturePilot at login"
                                                     target:self
                                                     action:@selector(launchAtLoginChanged:)];
    self.launchAtLoginButton.frame = NSMakeRect(24, 110, 300, 24);
    [content addSubview:self.launchAtLoginButton];

    self.conflictLabel = [self wrappingLabelWithText:@""
                                               frame:NSMakeRect(24, 68, 542, 38)];
    self.conflictLabel.textColor = NSColor.secondaryLabelColor;
    self.conflictLabel.font = [NSFont systemFontOfSize:11];
    [content addSubview:self.conflictLabel];

    NSTextField *privateAPI = [self wrappingLabelWithText:
        @"Exact finger counting uses macOS's private multitouch framework. A major macOS update may require a GesturePilot compatibility update."
        frame:NSMakeRect(24, 30, 542, 34)];
    privateAPI.textColor = NSColor.tertiaryLabelColor;
    privateAPI.font = [NSFont systemFontOfSize:10];
    [content addSubview:privateAPI];

    NSTextField *poweredBy = [self labelWithText:
        @"Powered by Codex and Digital Enablement Team"
        frame:NSMakeRect(24, 8, 542, 16)];
    poweredBy.alignment = NSTextAlignmentCenter;
    poweredBy.textColor = NSColor.tertiaryLabelColor;
    poweredBy.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    [content addSubview:poweredBy];

    [self refreshSettingsControls];
}

- (void)refreshSettingsControls {
    GPInputDeviceKind deviceKind = [self selectedDeviceKind];
    BOOL isMouse = deviceKind == GPInputDeviceKindMagicMouse;
    NSInteger fingerCount = [self fingerCount];
    self.fingerCountControl.selectedSegment = fingerCount - 3;
    self.settingsTitleLabel.stringValue = isMouse
        ? @"Magic Mouse gesture mappings"
        : @"Trackpad gesture mappings";
    self.introLabel.stringValue = isMouse
        ? @"Swipe with three fingers, or rest three fingers and physically click. Close Window uses the window’s close button; Quit App requests a normal quit."
        : [NSString stringWithFormat:
            @"Swipe with %ld fingers, or rest three fingers and physically click. The click always uses three fingers, regardless of your swipe setting.",
            (long)fingerCount];
    self.fingerCountTitleLabel.hidden = isMouse;
    self.fingerCountControl.hidden = isMouse;
    self.deviceHintLabel.hidden = !isMouse;
    self.enabledButton.title = isMouse
        ? @"Enable 3-finger Magic Mouse gestures"
        : @"Enable trackpad gestures";
    self.conflictLabel.stringValue = isMouse
        ? @"Place all three fingers before moving them. The Magic Mouse has a smaller touch surface, so use High sensitivity if a swipe is difficult to trigger."
        : [NSString stringWithFormat:
            @"If macOS also reacts to your %ld-finger swipe, choose the other finger count here or change Mission Control and App Exposé in System Settings › Trackpad › More Gestures.",
            (long)fingerCount];
    self.enabledButton.state = [self gesturesEnabledForDevice:deviceKind]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    self.enabledMenuItem.state = [self gesturesEnabledForDevice:GPInputDeviceKindTrackpad]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    self.mouseEnabledMenuItem.state = [self gesturesEnabledForDevice:GPInputDeviceKindMagicMouse]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    self.sensitivitySlider.minValue = isMouse ? 0.03 : 0.04;
    self.sensitivitySlider.doubleValue = [self sensitivityForDevice:deviceKind];
    self.inputSettingsButton.title = isMouse ? @"Mouse Settings" : @"Trackpad Settings";
    [self updateSensitivityLabel];

    for (NSNumber *key in self.mappingPopups) {
        GPSwipeDirection direction = (GPSwipeDirection)key.integerValue;
        [self.mappingPopups[key] selectItemAtIndex:[self actionForDirection:direction
                                                                  device:deviceKind]];
    }
    [self.clickMappingPopup selectItemAtIndex:[self clickActionForDevice:deviceKind]];

    BOOL trusted = [self.windowActions isAccessibilityTrustedPrompting:NO];
    self.permissionLabel.stringValue = trusted
        ? @"Accessibility: Granted"
        : @"Accessibility: Required";
    self.permissionLabel.textColor = trusted ? NSColor.systemGreenColor : NSColor.systemOrangeColor;

    self.launchAtLoginButton.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled
        ? NSControlStateValueOn
        : NSControlStateValueOff;
}

- (void)updateSensitivityLabel {
    double value = self.sensitivitySlider.doubleValue;
    self.sensitivityLabel.stringValue = value <= 0.07
        ? @"High"
        : (value <= 0.11 ? @"Medium" : @"Low");
}

- (void)updateMappingSummary {
    self.mappingMenuItem.title = [NSString stringWithFormat:
        @"Trackpad %ldF: ↓ %@ · ↑ %@  |  Mouse 3F: ↓ %@ · ↑ %@",
        (long)[self fingerCount],
        GPActionName([self actionForDirection:GPSwipeDirectionDown]),
        GPActionName([self actionForDirection:GPSwipeDirectionUp]),
        GPActionName([self actionForDirection:GPSwipeDirectionDown
                                       device:GPInputDeviceKindMagicMouse]),
        GPActionName([self actionForDirection:GPSwipeDirectionUp
                                       device:GPInputDeviceKindMagicMouse])];
}

- (void)restartDetectorForSettingsChange {
    self.detectorRecoveryGeneration += 1;
    [self configureDetectorFromSettings];
    [self.detector stop];
    if ([self anyGesturesEnabled]) {
        [self.detector start];
    } else {
        [self detectorStatusDidChange:@"Gestures disabled"];
    }
    [self updateMappingSummary];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.settingsWindow completionHandler:nil];
}

- (void)toggleEnabled:(id)sender {
    BOOL enabled = ![self gesturesEnabledForDevice:GPInputDeviceKindTrackpad];
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:GPEnabledKey];
    [self refreshSettingsControls];
    [self restartDetectorForSettingsChange];
}

- (void)toggleMouseEnabled:(id)sender {
    BOOL enabled = ![self gesturesEnabledForDevice:GPInputDeviceKindMagicMouse];
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:GPMouseEnabledKey];
    [self refreshSettingsControls];
    [self restartDetectorForSettingsChange];
}

- (void)enabledChanged:(NSButton *)sender {
    GPInputDeviceKind deviceKind = [self selectedDeviceKind];
    NSString *key = deviceKind == GPInputDeviceKindMagicMouse
        ? GPMouseEnabledKey
        : GPEnabledKey;
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn
                                          forKey:key];
    [self refreshSettingsControls];
    [self restartDetectorForSettingsChange];
}

- (void)mappingChanged:(NSPopUpButton *)sender {
    GPInputDeviceKind deviceKind = [self selectedDeviceKind];
    [NSUserDefaults.standardUserDefaults setInteger:sender.indexOfSelectedItem
                                             forKey:GPActionKeyForDevice(
                                                 deviceKind,
                                                 (GPSwipeDirection)sender.tag
                                             )];
    [self updateMappingSummary];
}

- (void)clickMappingChanged:(NSPopUpButton *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.indexOfSelectedItem
                                             forKey:GPClickActionKey([self selectedDeviceKind])];
    [self restartDetectorForSettingsChange];
}

- (void)inputDeviceChanged:(NSSegmentedControl *)sender {
    [self refreshSettingsControls];
}

- (void)fingerCountChanged:(NSSegmentedControl *)sender {
    NSInteger fingerCount = sender.selectedSegment == 0 ? 3 : 4;
    [NSUserDefaults.standardUserDefaults setInteger:fingerCount forKey:GPFingerCountKey];
    [self refreshSettingsControls];
    [self restartDetectorForSettingsChange];
}

- (void)sensitivityChanged:(NSSlider *)sender {
    GPInputDeviceKind deviceKind = [self selectedDeviceKind];
    NSString *key = deviceKind == GPInputDeviceKindMagicMouse
        ? GPMouseSensitivityKey
        : GPSensitivityKey;
    [NSUserDefaults.standardUserDefaults setDouble:sender.doubleValue forKey:key];
    [self.detector setMinimumDistance:sender.doubleValue forDevice:deviceKind];
    [self updateSensitivityLabel];
}

- (void)showSettings:(id)sender {
    NSLog(@"GesturePilot: Showing settings window");
    [self refreshSettingsControls];
    [self.settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)requestAccessibility:(id)sender {
    [self.windowActions isAccessibilityTrustedPrompting:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self refreshSettingsControls];
    });
}

- (void)openAccessibilitySettings:(id)sender {
    [self.windowActions openAccessibilitySettings];
}

- (void)openInputSettings:(id)sender {
    NSString *settingsPane = [self selectedDeviceKind] == GPInputDeviceKindMagicMouse
        ? @"com.apple.Mouse-Settings.extension"
        : @"com.apple.Trackpad-Settings.extension";
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"x-apple.systempreferences:%@",
        settingsPane]];
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)testMinimize:(id)sender {
    NSInteger count = [self.windowActions performAction:GPGestureActionMinimizeAll];
    [self detectorStatusDidChange:[NSString stringWithFormat:@"Test minimized %ld window%@",
                                   (long)count, count == 1 ? @"" : @"s"]];
}

- (void)testRestore:(id)sender {
    NSInteger count = [self.windowActions restoreWindows];
    [self detectorStatusDidChange:[NSString stringWithFormat:@"Restored %ld window%@",
                                   (long)count, count == 1 ? @"" : @"s"]];
}

- (void)restoreWindows:(id)sender {
    [self.windowActions restoreWindows];
}

- (void)launchAtLoginChanged:(NSButton *)sender {
    NSError *error = nil;
    BOOL success = sender.state == NSControlStateValueOn
        ? [SMAppService.mainAppService registerAndReturnError:&error]
        : [SMAppService.mainAppService unregisterAndReturnError:&error];

    if (!success) {
        sender.state = sender.state == NSControlStateValueOn
            ? NSControlStateValueOff
            : NSControlStateValueOn;
        [self showAlertWithTitle:@"Could not update Login Items"
                         message:error.localizedDescription ?: @"Unknown error"];
    }
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

@end

#pragma mark - Entry point and self-test

static int GPRunSelfTests(void) {
    GPSwipeDirection direction = GPSwipeDirectionDown;
    BOOL success = YES;

    success &= GPClassifySwipe(0.01, 0.10, 0.075, &direction) && direction == GPSwipeDirectionUp;
    success &= GPClassifySwipe(-0.01, -0.10, 0.075, &direction) && direction == GPSwipeDirectionDown;
    success &= GPClassifySwipe(0.10, 0.01, 0.075, &direction) && direction == GPSwipeDirectionRight;
    success &= GPClassifySwipe(-0.10, -0.01, 0.075, &direction) && direction == GPSwipeDirectionLeft;
    success &= !GPClassifySwipe(0.01, 0.02, 0.075, &direction);
    success &= !GPClassifySwipe(0.10, 0.09, 0.075, &direction);
    success &= GPDeviceKindForFamilyID(112) == GPInputDeviceKindMagicMouse;
    success &= GPDeviceKindForFamilyID(113) == GPInputDeviceKindMagicMouse;
    success &= GPDeviceKindForFamilyID(109) == GPInputDeviceKindTrackpad;
    success &= GPDeviceKindForFamilyID(130) == GPInputDeviceKindTrackpad;
    success &= GPDeviceKindForFamilyID(105) == GPInputDeviceKindUnknown;

    GPClickContact contacts[3] = {
        {1, {0.3, 0.5}}, {2, {0.5, 0.5}}, {3, {0.7, 0.5}},
    };
    GPClickChord chord = {0};
    GPUpdateClickChord(&chord, contacts, 3, 1.0);
    success &= !GPClickChordCanBegin(&chord, 1.05); // settle before pressing
    GPUpdateClickChord(&chord, contacts, 3, 1.12);
    success &= GPClickChordCanBegin(&chord, 1.13);
    contacts[0].position.x += 0.04;
    contacts[2].position.x -= 0.04;
    GPUpdateClickChord(&chord, contacts, 3, 1.14); // stationary centroid, moving fingers
    success &= !GPClickChordCanBegin(&chord, 1.15);
    GPUpdateClickChord(&chord, NULL, 0, 1.2);
    GPUpdateClickChord(&chord, contacts, 3, 1.3);
    GPUpdateClickChord(&chord, contacts, 3, 1.42);
    success &= GPClickChordCanBegin(&chord, 1.43); // lifting all fingers resets
    GPUpdateClickChord(&chord, contacts, 4, 1.44);
    GPUpdateClickChord(&chord, contacts, 3, 1.5);
    success &= !GPClickChordCanBegin(&chord, 1.51); // four-to-three is not a click chord
    GPUpdateClickChord(&chord, NULL, 0, 2.0);
    GPUpdateClickChord(&chord, contacts, 3, 2.1);
    contacts[0].identifier = 4;
    GPUpdateClickChord(&chord, contacts, 3, 2.22);
    success &= !GPClickChordCanBegin(&chord, 2.23); // replacement contact
    success &= [[[GPMultitouchDetector alloc] init] runClickSelfTests];
    success &= [[[GPMultitouchDetector alloc] init] runDeviceShutdownSelfTest];

    fprintf(stdout, "Gesture classifier self-test: %s\n", success ? "PASS" : "FAIL");
    return success ? 0 : 1;
}

static int GPListMultitouchDevices(void) {
    const char *path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";
    void *frameworkHandle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    if (!frameworkHandle) {
        fprintf(stderr, "Multitouch framework unavailable\n");
        return 1;
    }

    MTDeviceCreateListFunction createList = (MTDeviceCreateListFunction)dlsym(
        frameworkHandle,
        "MTDeviceCreateList"
    );
    MTDeviceGetFamilyIDFunction getFamilyID = (MTDeviceGetFamilyIDFunction)dlsym(
        frameworkHandle,
        "MTDeviceGetFamilyID"
    );
    if (!createList || !getFamilyID) {
        fprintf(stderr, "Multitouch device enumeration unavailable\n");
        dlclose(frameworkHandle);
        return 1;
    }

    CFArrayRef deviceList = createList();
    if (!deviceList) {
        fprintf(stderr, "No multitouch device list was returned\n");
        dlclose(frameworkHandle);
        return 1;
    }

    CFIndex count = CFArrayGetCount(deviceList);
    fprintf(stdout, "Multitouch devices: %ld\n", (long)count);
    for (CFIndex index = 0; index < count; index++) {
        void *device = (void *)CFArrayGetValueAtIndex(deviceList, index);
        int32_t familyID = 0;
        int32_t result = getFamilyID(device, &familyID);
        GPInputDeviceKind kind = result == 0
            ? GPDeviceKindForFamilyID(familyID)
            : GPInputDeviceKindUnknown;
        const char *name = kind == GPInputDeviceKindMagicMouse
            ? "Magic Mouse"
            : (kind == GPInputDeviceKindTrackpad ? "Trackpad" : "Unsupported");
        fprintf(stdout, "  %s (family %d)\n", name, familyID);
    }
    CFRelease(deviceList);
    dlclose(frameworkHandle);
    return 0;
}

static int GPTestDetectorRestart(void) {
    (void)NSApplication.sharedApplication;
    GPMultitouchDetector *detector = [[GPMultitouchDetector alloc] init];
    [detector setEnabled:YES forDevice:GPInputDeviceKindTrackpad];
    [detector setEnabled:YES forDevice:GPInputDeviceKindMagicMouse];
    [detector setClickEnabled:YES forDevice:GPInputDeviceKindTrackpad];
    [detector setClickEnabled:YES forDevice:GPInputDeviceKindMagicMouse];

    BOOL firstStart = [detector start];
    BOOL firstTrackpad = [detector isRunningForDevice:GPInputDeviceKindTrackpad];
    BOOL firstMouse = [detector isRunningForDevice:GPInputDeviceKindMagicMouse];
    BOOL firstClicks = [detector isClickMonitoringReady];
    [detector stop];
    [NSThread sleepForTimeInterval:0.2];

    BOOL secondStart = [detector start];
    BOOL secondTrackpad = [detector isRunningForDevice:GPInputDeviceKindTrackpad];
    BOOL secondMouse = [detector isRunningForDevice:GPInputDeviceKindMagicMouse];
    BOOL secondClicks = [detector isClickMonitoringReady];
    [detector stop];

    NSString *report = [NSString stringWithFormat:
        @"Detector restart: first=%@ trackpad=%@ mouse=%@ clicks=%@; second=%@ trackpad=%@ mouse=%@ clicks=%@\n",
        firstStart ? @"yes" : @"no",
        firstTrackpad ? @"yes" : @"no",
        firstMouse ? @"yes" : @"no",
        firstClicks ? @"yes" : @"no",
        secondStart ? @"yes" : @"no",
        secondTrackpad ? @"yes" : @"no",
        secondMouse ? @"yes" : @"no",
        secondClicks ? @"yes" : @"no"];
    fprintf(stdout, "%s", report.UTF8String);
    [report writeToFile:@"/private/tmp/GesturePilot-detector-restart-test.txt"
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];
    return firstStart && firstTrackpad && firstMouse &&
        secondStart && secondTrackpad && secondMouse && firstClicks && secondClicks ? 0 : 1;
}

static BOOL GPWaitForTestCondition(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return condition();
}

static int GPTestCloseQuitFixture(void) {
    (void)NSApplication.sharedApplication;
    NSString *root = @"/private/tmp/GesturePilot-ActionTest";
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:
        @"com.arun.GesturePilot.ActionTest"];
    if (apps.count != 1) return 1;
    NSRunningApplication *fixture = apps.firstObject;
    if (![fixture.bundleURL.path isEqualToString:[root stringByAppendingPathComponent:
        @"GesturePilotActionTest.app"]]) return 1;
    GPWindowActions *actions = [[GPWindowActions alloc] init];
    AXUIElementRef application = AXUIElementCreateApplication(fixture.processIdentifier);
    AXUIElementRef window = [actions copyCurrentWindowForApplication:fixture];
    if (!window) {
        CFRelease(application);
        return 1;
    }
    BOOL initiallyTwo = [actions windowsForApplication:application].count == 2;
    NSString *closeResult = [root stringByAppendingPathComponent:@"close-result"];
    NSString *quitResult = [root stringByAppendingPathComponent:@"quit-result"];
    [actions pressWindowButton:kAXCloseButtonAttribute window:window];
    BOOL closeVeto = GPWaitForTestCondition(^BOOL{
        return [[NSString stringWithContentsOfFile:closeResult encoding:NSUTF8StringEncoding
                                            error:nil] isEqualToString:@"close-cancelled"];
    }) && [actions windowsForApplication:application].count == 2;
    [@"yes" writeToFile:[root stringByAppendingPathComponent:@"allow-close"]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [actions pressWindowButton:kAXCloseButtonAttribute window:window];
    BOOL oneClosed = GPWaitForTestCondition(^BOOL{
        return [actions windowsForApplication:application].count == 1;
    });
    CFRelease(window);
    [actions requestQuitApplication:fixture];
    BOOL quitVeto = GPWaitForTestCondition(^BOOL{
        return [[NSString stringWithContentsOfFile:quitResult encoding:NSUTF8StringEncoding
                                            error:nil] isEqualToString:@"quit-cancelled"];
    }) && !fixture.terminated;
    [@"yes" writeToFile:[root stringByAppendingPathComponent:@"allow-quit"]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [actions requestQuitApplication:fixture];
    BOOL quitCompleted = GPWaitForTestCondition(^BOOL{ return fixture.terminated; });
    CFRelease(application);
    NSString *report = [NSString stringWithFormat:
        @"Initial two test windows: %@\nClose cancellation respected: %@\nOnly one test window closed: %@\nQuit cancellation respected: %@\nNormal quit completed: %@\n",
        initiallyTwo ? @"PASS" : @"FAIL", closeVeto ? @"PASS" : @"FAIL",
        oneClosed ? @"PASS" : @"FAIL", quitVeto ? @"PASS" : @"FAIL",
        quitCompleted ? @"PASS" : @"FAIL"];
    [report writeToFile:[root stringByAppendingPathComponent:@"test-result.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return initiallyTwo && closeVeto && oneClosed && quitVeto && quitCompleted ? 0 : 1;
}

static int GPDiagnoseWindows(NSString *bundleIdentifier) {
    BOOL trusted = AXIsProcessTrusted();
    NSMutableString *report = [NSMutableString stringWithFormat:
        @"Accessibility trusted: %@\n",
        trusted ? @"yes" : @"no"];
    fprintf(stdout, "Accessibility trusted: %s\n", trusted ? "yes" : "no");
    NSArray<NSRunningApplication *> *applications =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
    if (applications.count == 0) {
        fprintf(stderr, "Application is not running: %s\n", bundleIdentifier.UTF8String);
        [report appendFormat:@"Application is not running: %@\n", bundleIdentifier];
        NSString *path = [NSString stringWithFormat:
            @"/private/tmp/GesturePilot-window-diagnostics-%@.txt",
            bundleIdentifier];
        [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return 1;
    }

    NSRunningApplication *application = applications.firstObject;
    AXUIElementRef applicationElement = AXUIElementCreateApplication(application.processIdentifier);
    CFTypeRef focusedWindow = NULL;
    CFTypeRef mainWindow = NULL;
    CFTypeRef windowsValue = NULL;
    AXError focusedResult = AXUIElementCopyAttributeValue(
        applicationElement,
        kAXFocusedWindowAttribute,
        &focusedWindow
    );
    AXError mainResult = AXUIElementCopyAttributeValue(
        applicationElement,
        kAXMainWindowAttribute,
        &mainWindow
    );
    AXError windowsResult = AXUIElementCopyAttributeValue(
        applicationElement,
        kAXWindowsAttribute,
        &windowsValue
    );
    NSArray *windows = windowsResult == kAXErrorSuccess && windowsValue
        ? (__bridge NSArray *)windowsValue
        : @[];
    fprintf(stdout,
            "Bundle: %s, PID: %d, focused=%d/%s, main=%d/%s, windows=%d/%ld\n",
            bundleIdentifier.UTF8String,
            application.processIdentifier,
            focusedResult,
            focusedWindow ? "yes" : "no",
            mainResult,
            mainWindow ? "yes" : "no",
            windowsResult,
            (long)windows.count);
    [report appendFormat:
        @"Bundle: %@, PID: %d, focused=%d/%@, main=%d/%@, windows=%d/%ld\n",
        bundleIdentifier,
        application.processIdentifier,
        focusedResult,
        focusedWindow ? @"yes" : @"no",
        mainResult,
        mainWindow ? @"yes" : @"no",
        windowsResult,
        (long)windows.count];

    for (NSUInteger index = 0; index < windows.count; index++) {
        AXUIElementRef window = (__bridge AXUIElementRef)windows[index];
        Boolean minimizedSettable = false;
        AXError settableResult = AXUIElementIsAttributeSettable(
            window,
            kAXMinimizedAttribute,
            &minimizedSettable
        );
        CFTypeRef minimizeButton = NULL;
        AXError buttonResult = AXUIElementCopyAttributeValue(
            window,
            kAXMinimizeButtonAttribute,
            &minimizeButton
        );
        fprintf(stdout,
                "  window %lu: focused=%s, main=%s, minimized-settable=%d/%s, minimize-button=%d/%s\n",
                (unsigned long)index,
                focusedWindow && CFEqual(window, focusedWindow) ? "yes" : "no",
                mainWindow && CFEqual(window, mainWindow) ? "yes" : "no",
                settableResult,
                minimizedSettable ? "yes" : "no",
                buttonResult,
                minimizeButton ? "yes" : "no");
        [report appendFormat:
            @"  window %lu: focused=%@, main=%@, minimized-settable=%d/%@, minimize-button=%d/%@\n",
            (unsigned long)index,
            focusedWindow && CFEqual(window, focusedWindow) ? @"yes" : @"no",
            mainWindow && CFEqual(window, mainWindow) ? @"yes" : @"no",
            settableResult,
            minimizedSettable ? @"yes" : @"no",
            buttonResult,
            minimizeButton ? @"yes" : @"no"];
        if (minimizeButton) CFRelease(minimizeButton);
    }

    if (focusedWindow) CFRelease(focusedWindow);
    if (mainWindow) CFRelease(mainWindow);
    if (windowsValue) CFRelease(windowsValue);
    CFRelease(applicationElement);
    NSString *path = [NSString stringWithFormat:
        @"/private/tmp/GesturePilot-window-diagnostics-%@.txt",
        bundleIdentifier];
    [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return trusted ? 0 : 2;
}

static int GPTestCurrentWindowAction(GPGestureAction action) {
    GPWindowActions *windowActions = [[GPWindowActions alloc] init];
    NSInteger affected = [windowActions performAction:action];
    NSString *result = [NSString stringWithFormat:
        @"%@ (%ld)\n",
        GPActionName(action),
        (long)affected];
    [result writeToFile:@"/private/tmp/GesturePilot-window-action-test.txt"
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];
    return affected == 1 ? 0 : 1;
}

// Read only the system overview's accessibility structure; never workbook cells.
static void GPAppendOverviewTree(AXUIElementRef element, NSMutableString *report,
                                NSUInteger depth, NSUInteger *budget) {
    if (depth > 5 || *budget == 0) return;
    *budget -= 1;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *attribute in @[@"AXRole", @"AXSubrole", @"AXIdentifier", @"AXTitle"]) {
        CFTypeRef value = NULL;
        if (AXUIElementCopyAttributeValue(element, (__bridge CFStringRef)attribute, &value)
            == kAXErrorSuccess && value) {
            if (CFGetTypeID(value) == CFStringGetTypeID()) {
                [parts addObject:[NSString stringWithFormat:@"%@=%@", attribute, (__bridge NSString *)value]];
            }
            CFRelease(value);
        }
    }
    [report appendFormat:@"%*s%@\n", (int)depth * 2, "", [parts componentsJoinedByString:@" "]];
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &value);
    if (error == kAXErrorSuccess && value && CFGetTypeID(value) == CFArrayGetTypeID()) {
        for (id child in (__bridge NSArray *)value) {
            GPAppendOverviewTree((__bridge AXUIElementRef)child, report, depth + 1, budget);
        }
    }
    if (value) CFRelease(value);
}

static NSString *GPOverviewDiagnostic(void) {
    NSMutableString *report = [NSMutableString stringWithFormat:@"Accessibility trusted: %@\n",
                               AXIsProcessTrusted() ? @"yes" : @"no"];
    for (NSString *bundle in @[@"com.apple.dock", @"com.apple.WindowManager"]) {
        for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle]) {
            [report appendFormat:@"System app: %@\n", bundle];
            AXUIElementRef element = AXUIElementCreateApplication(app.processIdentifier);
            AXUIElementSetMessagingTimeout(element, 0.3);
            NSUInteger budget = 120;
            GPAppendOverviewTree(element, report, 0, &budget);
            CFRelease(element);
        }
    }
    return report;
}

static int GPTestOverviewAction(GPGestureAction action) {
    (void)NSApplication.sharedApplication;
    NSString *target = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier ?: @"unknown";
    __block BOOL done = NO;
    __block BOOL accepted = NO;
    GPLaunchOverview(action, ^(NSError *error) {
        accepted = error == nil;
        // Observe after the animation, rather than treating launch as proof of an open view.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSString *report = [NSString stringWithFormat:
                @"%@ — %@\nForeground before: %@\n%@",
                GPActionName(action), error ? error.localizedDescription : @"request accepted",
                target, GPOverviewDiagnostic()];
            [report writeToFile:@"/private/tmp/GesturePilot-overview-test.txt"
                     atomically:YES encoding:NSUTF8StringEncoding error:nil];
            done = YES;
        });
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:12];
    while (!done && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return done && accepted ? 0 : 1;
}

static int GPTestMinimizeRestoreCurrentWindow(void) {
    GPWindowActions *windowActions = [[GPWindowActions alloc] init];
    NSInteger minimized = [windowActions performAction:GPGestureActionMinimizeCurrent];
    [NSThread sleepForTimeInterval:0.4];
    NSInteger restored = [windowActions performAction:GPGestureActionRestore];
    NSString *result = [NSString stringWithFormat:
        @"Minimize Current Window (%ld)\nRestore Minimized Windows (%ld)\n",
        (long)minimized,
        (long)restored];
    [result writeToFile:@"/private/tmp/GesturePilot-window-action-test.txt"
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];
    return minimized == 1 && restored == 1 ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
            return GPRunSelfTests();
        }
        if (argc == 2 && strcmp(argv[1], "--list-devices") == 0) {
            return GPListMultitouchDevices();
        }
        if (argc == 2 && strcmp(argv[1], "--test-detector-restart") == 0) {
            return GPTestDetectorRestart();
        }
        if (argc == 2 && strcmp(argv[1], "--test-close-quit-fixture") == 0) {
            return GPTestCloseQuitFixture();
        }
        if (argc == 3 && strcmp(argv[1], "--diagnose-windows") == 0) {
            return GPDiagnoseWindows([NSString stringWithUTF8String:argv[2]]);
        }
        if (argc == 2 && strcmp(argv[1], "--test-minimize-current") == 0) {
            return GPTestCurrentWindowAction(GPGestureActionMinimizeCurrent);
        }
        if (argc == 2 && strcmp(argv[1], "--test-mission-control") == 0) {
            return GPTestOverviewAction(GPGestureActionMissionControl);
        }
        if (argc == 2 && strcmp(argv[1], "--test-app-expose") == 0) {
            return GPTestOverviewAction(GPGestureActionAppExpose);
        }
        if (argc == 2 && strcmp(argv[1], "--diagnose-overview") == 0) {
            (void)NSApplication.sharedApplication;
            [GPOverviewDiagnostic() writeToFile:@"/private/tmp/GesturePilot-overview-state.txt"
                                    atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return 0;
        }
        if (argc == 2 && strcmp(argv[1], "--test-minimize-restore-current") == 0) {
            return GPTestMinimizeRestoreCurrentWindow();
        }

        NSApplication *application = NSApplication.sharedApplication;
        GPAppDelegate *delegate = [[GPAppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
