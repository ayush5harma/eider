// The test probe: an iOS app that reports what the Mac hands it, so an
// install can be judged by effect rather than by exit status. Every line
// goes to Documents/probe.log in the app's home, which after an
// ipa-install-on-mac install is ~/Library/Containers/<bundle id>/Data.
//
//   launch   idiom, screen bounds/native bounds/scale, device model as UIKit
//            and sysctl report it (a spoofed model shows up here)
//   layout   the view and window size on every layout pass (window resizes,
//            a forced resolution)
//   touch    every touch phase with its point and its position as a
//            fraction of the view -- a keymapped key arrives as a touch
//   press    hardware key presses that reach the responder chain
//   text     the text field's contents as typed
//   keychain a generic password added on the first launch and read back on
//            every later one (the installer's keychain shim, or PlayChain)
//   keychain-shared  the same with a shared access group in the data
//            protection keychain, as Google's SSO stores its tokens
//   keychain-flags  a synchronizable item with an access group, read back
//            with query flags that describe no item, then updated and deleted
//            by access group
//   groupdefaults / groupcf  a value in the signed app group's preferences,
//            through NSUserDefaults(suiteName:) and the CFPreferences C API,
//            added on the first launch and read back on every later one
//   groupdomain / unsigned / groupsql / groupcoord / kvs  the group's
//            preferences as a persistent domain, an unsigned group's suite,
//            SQLite and coordinated files in the group's folder, and
//            NSUbiquitousKeyValueStore (see groupStoresRoundTrip)
//   group    an app group's folder and whether a file could be written in it
//            (the installer's app-group shim puts it inside the container)
//   quirk    whether the installer's quirk table reached this app: a BOOL
//            getter it forces to YES, and an NSInteger getter it must not touch
//   gl       which image dlsym(RTLD_DEFAULT, "glCreateShader") resolves to
//            (the probe links OpenGL ES, so the installer adds its redirect)
//
// Built by test/make-probe-ipa.sh; no Xcode project.
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <OpenGLES/ES2/gl.h>
#include <dlfcn.h>
#include <sqlite3.h>
#include <sys/sysctl.h>

static NSString *logPath;

// From the embedded ProbeKit.framework (test/make-probe-ipa.sh).
extern const char *probekit_hello(void);

static void plog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void plog(NSString *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  NSString *line = [NSString stringWithFormat:@"%.3f %@\n", NSDate.date.timeIntervalSince1970, msg];
  NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
  NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:logPath];
  if (!h) {
    [data writeToFile:logPath atomically:NO];
    return;
  }
  [h seekToEndOfFile];
  [h writeData:data];
  [h closeFile];
}

static NSString *sysctlString(const char *name) {
  size_t len = 0;
  if (sysctlbyname(name, NULL, &len, NULL, 0) != 0 || len == 0) return @"?";
  char *buf = malloc(len);
  if (!buf || sysctlbyname(name, buf, &len, NULL, 0) != 0) { free(buf); return @"?"; }
  NSString *s = [NSString stringWithUTF8String:buf];
  free(buf);
  return s ?: @"?";
}

// One generic password: read it back if an earlier launch stored it, else
// store one. A keychain that does not persist logs "add" on every launch.
static void keychainRoundTrip(void) {
  NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                          (__bridge id)kSecAttrService: @"ipa-probe", (__bridge id)kSecAttrAccount: @"probe",
                          (__bridge id)kSecReturnData: @YES};
  CFTypeRef result = NULL;
  OSStatus rc = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
  if (rc == errSecSuccess && result) {
    NSString *v = [[NSString alloc] initWithData:(__bridge_transfer NSData *)result encoding:NSUTF8StringEncoding];
    plog(@"keychain read=%@", v);
    return;
  }
  NSString *value = [NSString stringWithFormat:@"v-%.0f", NSDate.date.timeIntervalSince1970];
  NSDictionary *item = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecAttrService: @"ipa-probe", (__bridge id)kSecAttrAccount: @"probe",
                         (__bridge id)kSecValueData: [value dataUsingEncoding:NSUTF8StringEncoding]};
  plog(@"keychain miss=%d add=%d value=%@", (int)rc, (int)SecItemAdd((__bridge CFDictionaryRef)item, NULL), value);
}

// An app group's folder: ask for it, create it as an app with the real
// entitlement would find it already created, and write a file into it, as
// WhatsApp does with its CoreData store. Without the installer's app-group
// shim the folder is under ~/Library/Group Containers and System Policy
// denies the create.
static void groupContainerWrite(void) {
  NSURL *dir = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.ipa.probe.shared"];
  NSURL *file = [dir URLByAppendingPathComponent:@"probe-group.txt"];
  NSError *error = nil;
  BOOL wrote = file
    && [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&error]
    && [@"group" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error];
  plog(@"group write=%d path=%@ error=%@", wrote, dir.path ?: @"(nil)", error.localizedDescription ?: @"none");
}

// The app group the probe was signed with (make-probe-ipa.sh records it in
// Info.plist as ProbeAppGroup), so a test can give each run a fresh group.
static NSString *signedAppGroup(void) {
  return [NSBundle.mainBundle objectForInfoDictionaryKey:@"ProbeAppGroup"] ?: @"group.local.ipa-install-on-mac.probe";
}

// The app group's preferences, through both APIs Google's SDKs use:
// NSUserDefaults(suiteName:) and the CFPreferences C functions
// (GoogleUtilities' GULUserDefaults). Read back if an earlier launch stored
// them, else store them; a store that does not persist logs "add" every time.
static void groupDefaultsRoundTrip(void) {
  NSString *group = signedAppGroup();
  NSString *value = [NSString stringWithFormat:@"g-%.0f", NSDate.date.timeIntervalSince1970];
  NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:group];
  NSString *stored = [defaults stringForKey:@"probe"];
  if (stored) {
    plog(@"groupdefaults read=%@", stored);
  } else {
    [defaults setObject:value forKey:@"probe"];
    plog(@"groupdefaults miss add=%@ sync=%d", value, [defaults synchronize]);
  }
  CFStringRef app = (__bridge CFStringRef)group;
  CFPropertyListRef cf = CFPreferencesCopyAppValue(CFSTR("probe-cf"), app);
  if (cf && CFGetTypeID(cf) == CFStringGetTypeID()) {
    plog(@"groupcf read=%@", (__bridge NSString *)cf);
  } else {
    CFPreferencesSetAppValue(CFSTR("probe-cf"), (__bridge CFStringRef)value, app);
    plog(@"groupcf miss add=%@ sync=%d", value, CFPreferencesAppSynchronize(app));
  }
  if (cf) CFRelease(cf);
}

// A generic password the way Google's SSO stores its tokens: a shared access
// group and the data protection keychain.
static void sharedKeychainRoundTrip(void) {
  NSDictionary *base = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecAttrService: @"ipa-probe-shared", (__bridge id)kSecAttrAccount: @"probe",
                         (__bridge id)kSecAttrAccessGroup: @"TEAM123456.local.ipa-install-on-mac.shared",
                         (__bridge id)kSecUseDataProtectionKeychain: @YES};
  NSMutableDictionary *query = [base mutableCopy];
  query[(__bridge id)kSecReturnData] = @YES;
  CFTypeRef result = NULL;
  OSStatus rc = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
  if (rc == errSecSuccess && result) {
    NSString *v = [[NSString alloc] initWithData:(__bridge_transfer NSData *)result encoding:NSUTF8StringEncoding];
    plog(@"keychain-shared read=%@", v);
    return;
  }
  NSString *value = [NSString stringWithFormat:@"s-%.0f", NSDate.date.timeIntervalSince1970];
  NSMutableDictionary *item = [base mutableCopy];
  item[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
  plog(@"keychain-shared miss=%d add=%d value=%@", (int)rc, (int)SecItemAdd((__bridge CFDictionaryRef)item, NULL), value);
}

// A synchronizable item with a non-default accessibility and an access
// group, read back with query flags apps pass that describe no item
// (kSecUseNoAuthenticationUI, kSecAttrSynchronizableAny, kSecMatchLimitOne),
// then updated and deleted by a query naming the access group. On the launch
// after it the item is gone, so the next launch adds it again.
static void flaggedKeychainRoundTrip(void) {
  NSDictionary *base = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecAttrService: @"ipa-probe-flags", (__bridge id)kSecAttrAccount: @"probe",
                         (__bridge id)kSecAttrAccessGroup: @"TEAM123456.local.ipa-install-on-mac.flags",
                         (__bridge id)kSecUseDataProtectionKeychain: @YES};
  NSMutableDictionary *query = [base mutableCopy];
  query[(__bridge id)kSecUseNoAuthenticationUI] = @YES;
  query[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecReturnAttributes] = @YES;
  CFTypeRef result = NULL;
  OSStatus rc = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
  if (rc != errSecSuccess || !result) {
    NSString *value = [NSString stringWithFormat:@"f-%.0f", NSDate.date.timeIntervalSince1970];
    NSMutableDictionary *item = [base mutableCopy];
    item[(__bridge id)kSecAttrSynchronizable] = @YES;
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    item[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
    plog(@"keychain-flags miss=%d add=%d value=%@", (int)rc, (int)SecItemAdd((__bridge CFDictionaryRef)item, NULL), value);
    return;
  }
  NSDictionary *found = (__bridge_transfer NSDictionary *)result;
  NSString *v = [[NSString alloc] initWithData:found[(__bridge id)kSecValueData] encoding:NSUTF8StringEncoding];
  NSMutableDictionary *byGroup = [base mutableCopy];
  byGroup[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
  NSDictionary *change = @{(__bridge id)kSecValueData: [@"updated" dataUsingEncoding:NSUTF8StringEncoding]};
  OSStatus updated = SecItemUpdate((__bridge CFDictionaryRef)byGroup, (__bridge CFDictionaryRef)change);
  CFTypeRef again = NULL;
  NSMutableDictionary *dataOnly = [query mutableCopy];
  [dataOnly removeObjectForKey:(__bridge id)kSecReturnAttributes];
  OSStatus reread = SecItemCopyMatching((__bridge CFDictionaryRef)dataOnly, &again);
  NSString *after = reread == errSecSuccess ? [[NSString alloc] initWithData:(__bridge_transfer NSData *)again encoding:NSUTF8StringEncoding] : @"-";
  OSStatus deleted = SecItemDelete((__bridge CFDictionaryRef)byGroup);
  OSStatus gone = SecItemCopyMatching((__bridge CFDictionaryRef)dataOnly, NULL);
  plog(@"keychain-flags read=%@ pdmn=%@ sync=%@ update=%d reread=%@ delete=%d gone=%d", v,
       found[(__bridge id)kSecAttrAccessible], found[(__bridge id)kSecAttrSynchronizable],
       (int)updated, after, (int)deleted, (int)gone);
}

// The rest of what an app keeps under its app group, each added on the first
// launch and read back on the next:
//   groupdomain    the group's preferences seen as a persistent domain
//                  (UserDefaults.persistentDomain(forName:), which Swift code
//                  uses with removePersistentDomain(forName:) to clear a suite)
//   unsigned       preferences of a "group." suite the app is NOT signed for,
//                  as an app whose group id comes from its Info.plist uses
//   groupsql       a SQLite database (WAL, as Core Data uses) in the group's folder
//   groupcoord     a file written through NSFileCoordinator in the group's folder
//   kvs            NSUbiquitousKeyValueStore (no iCloud entitlement here)
static void groupStoresRoundTrip(void) {
  NSString *group = signedAppGroup();
  NSString *value = [NSString stringWithFormat:@"q-%.0f", NSDate.date.timeIntervalSince1970];
  NSDictionary *domain = [NSUserDefaults.standardUserDefaults persistentDomainForName:group];
  plog(@"groupdomain probe=%@", domain[@"probe"] ?: @"(none)");

  NSString *unsignedGroup = @"group.local.eider-e2e.unsigned";
  NSUserDefaults *other = [[NSUserDefaults alloc] initWithSuiteName:unsignedGroup];
  NSString *stored = [other stringForKey:@"probe"];
  if (stored) {
    plog(@"unsigned read=%@", stored);
  } else {
    [other setObject:value forKey:@"probe"];
    plog(@"unsigned miss add=%@ sync=%d", value, [other synchronize]);
  }

  NSURL *dir = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
  NSString *db = [dir URLByAppendingPathComponent:@"probe.sqlite"].path;
  sqlite3 *h = NULL;
  if (dir && sqlite3_open(db.fileSystemRepresentation, &h) == SQLITE_OK) {
    sqlite3_exec(h, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS t (v TEXT)", NULL, NULL, NULL);
    sqlite3_stmt *st = NULL;
    NSString *row = nil;
    if (sqlite3_prepare_v2(h, "SELECT v FROM t LIMIT 1", -1, &st, NULL) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW)
      row = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(st, 0)];
    sqlite3_finalize(st);
    if (row) {
      plog(@"groupsql read=%@", row);
    } else {
      NSString *sql = [NSString stringWithFormat:@"INSERT INTO t VALUES ('%@')", value];
      plog(@"groupsql miss add=%@ rc=%d", value, sqlite3_exec(h, sql.UTF8String, NULL, NULL, NULL));
    }
    sqlite3_close(h);
  } else {
    plog(@"groupsql open-failed path=%@", db ?: @"(nil)");
  }

  NSURL *file = [dir URLByAppendingPathComponent:@"coordinated.txt"];
  NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:NULL];
  if (text) {
    plog(@"groupcoord read=%@", text);
  } else {
    __block BOOL wrote = NO;
    NSError *error = nil;
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateWritingItemAtURL:file options:0 error:&error byAccessor:^(NSURL *url) {
      wrote = [value writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }];
    plog(@"groupcoord miss add=%@ wrote=%d", value, wrote);
  }

  NSUbiquitousKeyValueStore *kvs = NSUbiquitousKeyValueStore.defaultStore;
  NSString *kv = [kvs stringForKey:@"probe"];
  if (kv) {
    plog(@"kvs read=%@", kv);
  } else {
    [kvs setString:value forKey:@"probe"];
    plog(@"kvs miss add=%@ sync=%d", value, [kvs synchronize]);
  }
}

// Two methods the quirk table names for this app (AppQuirks.swift): the
// installer's quirks shim makes the BOOL getter answer YES and must leave the
// NSInteger getter alone.
@interface ProbeQuirkTarget : NSObject
- (BOOL)probeQuirkSwitch;
- (NSInteger)probeQuirkCount;
@end

@implementation ProbeQuirkTarget
- (BOOL)probeQuirkSwitch { return NO; }
- (NSInteger)probeQuirkCount { return 7; }
@end

static void quirkReport(void) {
  ProbeQuirkTarget *t = [ProbeQuirkTarget new];
  plog(@"quirk switch=%d count=%ld", t.probeQuirkSwitch, (long)t.probeQuirkCount);
}

static void glLookup(void) {
  Dl_info info = {0};
  void *p = dlsym(RTLD_DEFAULT, "glCreateShader");
  const char *img = (p && dladdr(p, &info) && info.dli_fname) ? strrchr(info.dli_fname, '/') + 1 : "none";
  // glGetError keeps the OpenGL ES link: the installer adds its redirect
  // only to apps that link it.
  plog(@"gl lookup=%s linked=%p", img, (void *)glGetError);
}

@interface ProbeView : UIView
@property(nonatomic, strong) UITextField *field;
@property(nonatomic, strong) NSMutableArray<NSValue *> *marks;
@end

@implementation ProbeView
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = UIColor.systemBackgroundColor;
    self.multipleTouchEnabled = YES;
    _marks = [NSMutableArray array];
    _field = [[UITextField alloc] initWithFrame:CGRectMake(24, 60, 320, 36)];
    _field.borderStyle = UITextBorderStyleRoundedRect;
    _field.placeholder = @"type here";
    _field.accessibilityIdentifier = @"probe.field";
    [_field addTarget:self action:@selector(textChanged:) forControlEvents:UIControlEventEditingChanged];
    [self addSubview:_field];
  }
  return self;
}

- (void)textChanged:(UITextField *)f {
  plog(@"text \"%@\"", f.text);
}

- (void)report:(NSString *)phase touches:(NSSet<UITouch *> *)touches {
  CGSize s = self.bounds.size;
  for (UITouch *t in touches) {
    CGPoint p = [t locationInView:self];
    plog(@"touch %@ x=%.1f y=%.1f nx=%.3f ny=%.3f view=%.0fx%.0f", phase, p.x, p.y,
         s.width > 0 ? p.x / s.width : 0, s.height > 0 ? p.y / s.height : 0, s.width, s.height);
    if ([phase isEqualToString:@"began"]) {
      [self.marks addObject:[NSValue valueWithCGPoint:p]];
      if (self.marks.count > 12) [self.marks removeObjectAtIndex:0];
      [self setNeedsDisplay];
    }
  }
}

- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self report:@"began" touches:t]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self report:@"moved" touches:t]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self report:@"ended" touches:t]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self report:@"cancelled" touches:t]; }

// A crosshair at the centre and a dot per recent touch, so a screenshot is
// evidence too.
- (void)drawRect:(CGRect)rect {
  CGSize s = self.bounds.size;
  [UIColor.systemGrayColor setStroke];
  UIBezierPath *cross = [UIBezierPath bezierPath];
  [cross moveToPoint:CGPointMake(s.width / 2 - 20, s.height / 2)];
  [cross addLineToPoint:CGPointMake(s.width / 2 + 20, s.height / 2)];
  [cross moveToPoint:CGPointMake(s.width / 2, s.height / 2 - 20)];
  [cross addLineToPoint:CGPointMake(s.width / 2, s.height / 2 + 20)];
  [cross stroke];
  [UIColor.systemRedColor setFill];
  for (NSValue *v in self.marks) {
    CGPoint p = v.CGPointValue;
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(p.x - 8, p.y - 8, 16, 16)] fill];
  }
  NSString *size = [NSString stringWithFormat:@"%.0f x %.0f pt", s.width, s.height];
  [size drawAtPoint:CGPointMake(24, 110)
     withAttributes:@{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular],
                      NSForegroundColorAttributeName: UIColor.labelColor}];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  plog(@"layout view=%.0fx%.0f window=%@", self.bounds.size.width, self.bounds.size.height,
       NSStringFromCGRect(self.window.frame));
  [self setNeedsDisplay];
}
@end

@interface ProbeViewController : UIViewController
@end

@implementation ProbeViewController
- (void)loadView {
  self.view = [[ProbeView alloc] initWithFrame:UIScreen.mainScreen.bounds];
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [self becomeFirstResponder];
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  for (UIPress *p in presses) {
    plog(@"press began key=\"%@\" usage=%ld", p.key.charactersIgnoringModifiers ?: @"", (long)p.key.keyCode);
  }
  [super pressesBegan:presses withEvent:event];
}
@end

// Scene lifecycle: UIKit traps an app linked against the iOS 27 SDK that
// has not adopted it (_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption),
// on iOS and in a converted app alike once the installer keeps the binary's
// own SDK version.
@interface ProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ProbeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
  UIWindowScene *ws = (UIWindowScene *)scene;
  UIScreen *sc = ws.screen;
  plog(@"launch idiom=%ld screen=%.0fx%.0f native=%.0fx%.0f scale=%.2f nativeScale=%.2f model=\"%@\" "
       @"hw.machine=%@ hw.model=%@ bundle=%@ %s",
       (long)UIDevice.currentDevice.userInterfaceIdiom, sc.bounds.size.width, sc.bounds.size.height,
       sc.nativeBounds.size.width, sc.nativeBounds.size.height, sc.scale, sc.nativeScale,
       UIDevice.currentDevice.model, sysctlString("hw.machine"), sysctlString("hw.model"),
       NSBundle.mainBundle.bundleIdentifier, probekit_hello());
  self.window = [[UIWindow alloc] initWithWindowScene:ws];
  if ([[NSBundle.mainBundle objectForInfoDictionaryKey:@"ProbeBlankWindow"] boolValue]) {
    // What YouTube did under Catalyst's late first scene (2026-11-26): its
    // first screen was built and presented from, but never attached to the
    // window, which stays empty. Eider's doctor must call this
    // window_not_attached.
    [self.window makeKeyAndVisible];
    UIViewController *detached = [ProbeViewController new];
    [detached loadViewIfNeeded];
    dispatch_async(dispatch_get_main_queue(), ^{
      [detached presentViewController:[UIViewController new] animated:NO completion:nil];
      plog(@"blank-window presented from a detached controller");
    });
    return;
  }
  self.window.rootViewController = [ProbeViewController new];
  [self.window makeKeyAndVisible];
}
@end

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ProbeAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
  NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
  [NSFileManager.defaultManager createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:NULL];
  logPath = [docs stringByAppendingPathComponent:@"probe.log"];
  keychainRoundTrip();
  sharedKeychainRoundTrip();
  flaggedKeychainRoundTrip();
  groupDefaultsRoundTrip();
  groupStoresRoundTrip();
  groupContainerWrite();
  quirkReport();
  glLookup();
  return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)app
    configurationForConnectingSceneSession:(UISceneSession *)session
                                   options:(UISceneConnectionOptions *)options {
  UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
  c.delegateClass = ProbeSceneDelegate.class;
  return c;
}
@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeAppDelegate.class));
  }
}
