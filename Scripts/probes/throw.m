// A --dylib fixture for Scripts/e2e.sh's crash checks (EIDER_E2E_CRASH_CHECKS=1)
// that reproduces a tweak crashing its host: its constructor schedules an uncaught NSInvalidArgumentException on the
// main queue a few seconds after launch, the way the field crash of 2026-11-25
// did (a dylib's +[FCAlertView getResourcesBundle] passed a nil URL to
// +[NSBundle bundleWithURL:] about 4 s after the app started). Thrown from a
// main-queue block it reaches CoreFoundation's top-level handler, which logs
// "*** Terminating app due to uncaught exception ..." and a backtrace, as a
// real app does; thrown from the constructor itself it would die before main
// without that line.
#import <Foundation/Foundation.h>

@interface ThrowingTweak : NSObject
+ (NSBundle *)getResourcesBundle;
@end

@implementation ThrowingTweak
+ (NSBundle *)getResourcesBundle {
  NSURL *missing = nil;
  return [NSBundle bundleWithURL:missing];
}
@end

__attribute__((constructor)) static void throw_soon(void) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [ThrowingTweak getResourcesBundle];
  });
}
