// Per-app workarounds for an app's own code that misbehaves under Mac
// Catalyst. Linked only into the apps ShimLinker.quirkBundleIDs names; each
// workaround also checks that the class and method it changes exist, so an
// app version without them is left alone.
//
// YouTube (com.google.ios.youtube): blank window.
// Why: YouTube's -application:didFinishLaunchingWithOptions: returns at once
// and its launch sequence builds YTAppViewControllerImpl asynchronously on
// the main queue; it installs that controller as the root of the window its
// scene delegate made. On iOS the first scene connects right after launch, so
// the window exists first. Under Mac Catalyst the scene connects later (0.5 s
// to 2.3 s after didFinishLaunching, measured 2026-11-26 on macOS 27.3 with
// YouTube 21.47.6), the controller finds no window, and the window the scene
// delegate then makes stays hidden with no root view controller: an empty
// window, "Attempt to present <YTFirstTimeSignInViewController> ... whose view
// is not in the window hierarchy", 8 accessibility elements. YouTube's own fix
// for a late scene is server-gated, -[YTColdConfig
// mainAppCoreClientIos27SceneDelegateLaunchSequenceFixEnabled], and the server
// left it off for this client. With it answering YES the scene delegate
// installs the controller and shows the window (79 accessibility elements and
// the first-run sign-in sheet in the same measurement).
// What: that one getter answers YES.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static BOOL answer_yes(id self, SEL _cmd) { return YES; }

// Make -[cls sel] (a BOOL getter) answer YES; false when the app has no such method.
static BOOL force_yes(const char *cls, const char *sel) {
    Class c = objc_getClass(cls);
    Method m = c ? class_getInstanceMethod(c, sel_registerName(sel)) : NULL;
    if (m == NULL || strcmp(method_getTypeEncoding(m), "B16@0:8") != 0) return NO;
    method_setImplementation(m, (IMP)answer_yes);
    return YES;
}

__attribute__((constructor)) static void ipaquirks_install(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    if (!force_yes("YTColdConfig", "mainAppCoreClientIos27SceneDelegateLaunchSequenceFixEnabled"))
        NSLog(@"ipaquirks: %@ has no YTColdConfig launch-sequence switch; left as it is", bundle);
}
