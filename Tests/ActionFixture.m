#import <AppKit/AppKit.h>

// Disposable windows for testing normal close/quit requests without user documents.
static NSString *const Root = @"/private/tmp/GesturePilot-ActionTest";

@interface GPActionFixture : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSMutableArray<NSWindow *> *windows;
@end

@implementation GPActionFixture
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.windows = [NSMutableArray array];
    for (NSInteger i = 0; i < 2; i++) {
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(300 + 80 * i, 300 + 80 * i, 420, 160)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            backing:NSBackingStoreBuffered defer:NO];
        window.title = [NSString stringWithFormat:@"GesturePilot disposable test %ld", (long)i + 1];
        window.releasedWhenClosed = NO;
        window.delegate = self;
        NSTextField *label = [NSTextField labelWithString:@"Temporary GesturePilot test window — no documents."];
        label.frame = NSMakeRect(15, 60, 390, 50);
        [window.contentView addSubview:label];
        [window orderFront:nil];
        [self.windows addObject:window];
    }
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
    BOOL allowed = [NSFileManager.defaultManager fileExistsAtPath:
        [Root stringByAppendingPathComponent:@"allow-close"]];
    [(allowed ? @"close-allowed" : @"close-cancelled")
        writeToFile:[Root stringByAppendingPathComponent:@"close-result"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return allowed;
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    BOOL allowed = [NSFileManager.defaultManager fileExistsAtPath:
        [Root stringByAppendingPathComponent:@"allow-quit"]];
    [(allowed ? @"quit-allowed" : @"quit-cancelled")
        writeToFile:[Root stringByAppendingPathComponent:@"quit-result"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return allowed ? NSTerminateNow : NSTerminateCancel;
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        GPActionFixture *delegate = [[GPActionFixture alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
