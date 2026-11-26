// App-group containers and preferences for an ad-hoc signed iOS app on macOS.
//
// Why: an ad-hoc signature cannot carry an application-groups entitlement
// that macOS honours (a "group."-prefixed group needs a provisioning profile,
// and nobody can get a profile for another team's group such as
// group.net.whatsapp.WhatsApp.shared). Without it macOS's System Policy
// denies every write under ~/Library/Group Containers/<group>, and a sandbox
// exception in the app's own entitlements does not lift that denial
// (measured 2026-11-10 on macOS 27.3 with WhatsApp/Watusi: "System Policy:
// WhatsApp deny(1) file-write-create .../group.net.whatsapp.WhatsApp.shared/Logs",
// then CoreData error 513 and WAHandleFailureInFunction -> abort at launch).
//
// What: containerURLForSecurityApplicationGroupIdentifier: answers with a
// directory inside the app's OWN sandbox container
// (~/Library/Containers/<bundle id>/Data/Library/Group Containers/<group>),
// created on first use. The app keeps one private copy of each group's data;
// nothing is shared with any other app, which is the point of the sandbox.
//
// The original implementation is called first and only its answer is
// moved: a tweak that hooked the same selector before this library loaded
// (injected libraries load last) still decides WHICH group a call resolves
// to. On macOS the original call creates nothing (measured: the probe's
// folder did not exist after it), so calling it has no side effect.
//
// The group's preferences are kept in the app's container too; see
// "Preferences" below.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <pwd.h>
#include <unistd.h>

// SecTask is in macOS's Security framework but not in the Catalyst headers.
typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

static NSURL *(*original_container_url)(id, SEL, NSString *);
static NSString *real_group_containers;   // ~/Library/Group Containers/ of the real home
static NSString *own_group_containers;    // the same folder inside the app's container
static NSMutableSet<NSString *> *created; // groups whose folder exists already
static NSSet<NSString *> *signed_groups;  // the app groups in this process's signature

static BOOL is_plain_group_id(NSString *group) {
    if (group.length == 0 || group.length > 255) return NO;
    if ([group hasPrefix:@"."] || [group containsString:@"/"]) return NO;
    return YES;
}

// The group's folder inside the app's container, created on first use; nil
// when it cannot be made.
static NSString *own_group_path(NSString *group) {
    NSString *path = [own_group_containers stringByAppendingPathComponent:group];
    @synchronized (created) {
        if (![created containsObject:group]) {
            NSError *error = nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:path
                                           withIntermediateDirectories:YES
                                                            attributes:@{NSFilePosixPermissions: @0700}
                                                                 error:&error]) {
                NSLog(@"ipagroups: could not create %@: %@", path, error);
                return nil;
            }
            [created addObject:group];
        }
    }
    return path;
}

// The group a call resolved to: the original answer's last component when it
// points at the real Group Containers folder, the asked-for id when it is nil.
// Anything else (a tweak that already moved it somewhere writable) is kept.
static NSString *group_to_move(NSURL *answer, NSString *asked) {
    if (answer == nil) return asked;
    NSString *path = answer.URLByStandardizingPath.path;
    if (![path hasPrefix:real_group_containers]) return nil;
    NSString *rest = [path substringFromIndex:real_group_containers.length];
    return [rest componentsSeparatedByString:@"/"].firstObject;
}

static NSURL *own_container_url(id self, SEL _cmd, NSString *group) {
    NSURL *answer = original_container_url(self, _cmd, group);
    NSString *resolved = group_to_move(answer, group);
    if (!is_plain_group_id(resolved)) return answer;
    NSString *path = own_group_path(resolved);
    return path ? [NSURL fileURLWithPath:path isDirectory:YES] : answer;
}

// ── Preferences ─────────────────────────────────────────────────────────────
// Why: an app group's preferences (NSUserDefaults(suiteName: group) and the
// CFPreferences functions with the group id as the application id, which
// Google's SDKs use for shared sign-in state) are refused for an app launched
// through LaunchServices (Finder, the Dock, `open`): cfprefsd binds the domain
// to no container and turns every write down ("Couldn't write values ...
// Container: (null) ... setting preferences outside an application's
// container requires user-preference-write"), while reads in the same process
// still answer the unsaved value, so nothing survives a relaunch. Measured
// 2026-11-26 on macOS 27.3: YouTube logged it for group.com.google.YouTube and
// group.com.google.common, and the e2e probe's group preferences were gone
// after kill -9 and relaunch on every launch through `open` (launched by exec
// from a shell they persisted). Handing the domain an explicit container,
// the group's folder above or the app's own container, was refused the same
// way: cfprefsd refuses a domain named after one of the app's own groups.
//
// What: the domain of each app group in the app's own signature is renamed
// "ipagroups.<group>", a name that is no group id, so cfprefsd stores it like
// any other suite of a sandboxed app, in
// ~/Library/Containers/<bundle id>/Data/Library/Preferences/ipagroups.<group>.plist.
// The rename is applied wherever the group id names a preferences domain:
// -[NSUserDefaults initWithSuiteName:], -addSuiteNamed:, -removeSuiteNamed:,
// the three persistent-domain methods (-persistentDomainForName:,
// -setPersistentDomain:forName:, -removePersistentDomainForName:, which Swift
// code calls as UserDefaults(suiteName: g)?.removePersistentDomain(forName: g)
// to clear a group's suite at sign-out; unrenamed, the read answered nothing,
// measured 2026-11-27 by the e2e probe, so a clear would have missed the
// values the suite kept), and every CFPreferences function that takes an
// application id.
// Like the folder, the values are private to this app.
//
// Only the app's signed groups are renamed. A "group." suite the app is not
// signed for (a group id read from its Info.plist, say) is an ordinary domain
// to cfprefsd and is stored in the container already (measured the same day:
// written, kill -9, read back after a relaunch through `open`).

static NSString *const kPrefsPrefix = @"ipagroups.";

static NSArray<NSString *> *groups_in_signature(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (task == NULL) return @[];
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
    CFRelease(task);
    id groups = CFBridgingRelease(value);
    if (![groups isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id g in groups) if ([g isKindOfClass:[NSString class]] && is_plain_group_id(g)) [out addObject:g];
    return out;
}

// The domain a group's preferences are stored under; any other name unchanged.
static NSString *prefs_domain(NSString *name) {
    if (name == nil || ![signed_groups containsObject:name]) return name;
    return [kPrefsPrefix stringByAppendingString:name];
}

static CFStringRef cf_domain(CFStringRef app) {
    if (app == NULL || CFGetTypeID(app) != CFStringGetTypeID()) return app;
    return (__bridge CFStringRef)prefs_domain((__bridge NSString *)app);
}

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

static CFPropertyListRef groups_copy_app_value(CFStringRef key, CFStringRef app) {
    return CFPreferencesCopyAppValue(key, cf_domain(app));
}
DYLD_INTERPOSE(groups_copy_app_value, CFPreferencesCopyAppValue)

static void groups_set_app_value(CFStringRef key, CFPropertyListRef value, CFStringRef app) {
    CFPreferencesSetAppValue(key, value, cf_domain(app));
}
DYLD_INTERPOSE(groups_set_app_value, CFPreferencesSetAppValue)

static Boolean groups_app_synchronize(CFStringRef app) {
    return CFPreferencesAppSynchronize(cf_domain(app));
}
DYLD_INTERPOSE(groups_app_synchronize, CFPreferencesAppSynchronize)

static Boolean groups_get_app_boolean(CFStringRef key, CFStringRef app, Boolean *valid) {
    return CFPreferencesGetAppBooleanValue(key, cf_domain(app), valid);
}
DYLD_INTERPOSE(groups_get_app_boolean, CFPreferencesGetAppBooleanValue)

static CFIndex groups_get_app_integer(CFStringRef key, CFStringRef app, Boolean *valid) {
    return CFPreferencesGetAppIntegerValue(key, cf_domain(app), valid);
}
DYLD_INTERPOSE(groups_get_app_integer, CFPreferencesGetAppIntegerValue)

static Boolean groups_app_value_is_forced(CFStringRef key, CFStringRef app) {
    return CFPreferencesAppValueIsForced(key, cf_domain(app));
}
DYLD_INTERPOSE(groups_app_value_is_forced, CFPreferencesAppValueIsForced)

static CFPropertyListRef groups_copy_value(CFStringRef key, CFStringRef app, CFStringRef user, CFStringRef host) {
    return CFPreferencesCopyValue(key, cf_domain(app), user, host);
}
DYLD_INTERPOSE(groups_copy_value, CFPreferencesCopyValue)

static void groups_set_value(CFStringRef key, CFPropertyListRef value, CFStringRef app, CFStringRef user, CFStringRef host) {
    CFPreferencesSetValue(key, value, cf_domain(app), user, host);
}
DYLD_INTERPOSE(groups_set_value, CFPreferencesSetValue)

static Boolean groups_synchronize(CFStringRef app, CFStringRef user, CFStringRef host) {
    return CFPreferencesSynchronize(cf_domain(app), user, host);
}
DYLD_INTERPOSE(groups_synchronize, CFPreferencesSynchronize)

static CFDictionaryRef groups_copy_multiple(CFArrayRef keys, CFStringRef app, CFStringRef user, CFStringRef host) {
    return CFPreferencesCopyMultiple(keys, cf_domain(app), user, host);
}
DYLD_INTERPOSE(groups_copy_multiple, CFPreferencesCopyMultiple)

static void groups_set_multiple(CFDictionaryRef set, CFArrayRef remove, CFStringRef app, CFStringRef user, CFStringRef host) {
    CFPreferencesSetMultiple(set, remove, cf_domain(app), user, host);
}
DYLD_INTERPOSE(groups_set_multiple, CFPreferencesSetMultiple)

static CFArrayRef groups_copy_key_list(CFStringRef app, CFStringRef user, CFStringRef host) {
    return CFPreferencesCopyKeyList(cf_domain(app), user, host);
}
DYLD_INTERPOSE(groups_copy_key_list, CFPreferencesCopyKeyList)

static void groups_add_suite(CFStringRef app, CFStringRef suite) {
    CFPreferencesAddSuitePreferencesToApp(cf_domain(app), cf_domain(suite));
}
DYLD_INTERPOSE(groups_add_suite, CFPreferencesAddSuitePreferencesToApp)

static void groups_remove_suite(CFStringRef app, CFStringRef suite) {
    CFPreferencesRemoveSuitePreferencesFromApp(cf_domain(app), cf_domain(suite));
}
DYLD_INTERPOSE(groups_remove_suite, CFPreferencesRemoveSuitePreferencesFromApp)

// NSUserDefaults calls CoreFoundation's internals, not the functions above.
typedef id (*suite_init_fn)(id, SEL, NSString *);
typedef void (*suite_fn)(id, SEL, NSString *);
typedef NSDictionary *(*domain_get_fn)(id, SEL, NSString *);
typedef void (*domain_set_fn)(id, SEL, NSDictionary *, NSString *);
static suite_init_fn original_init_suite;
static suite_fn original_add_suite, original_remove_suite, original_remove_domain;
static domain_get_fn original_get_domain;
static domain_set_fn original_set_domain;

static id groups_init_suite(id self, SEL _cmd, NSString *suite) {
    return original_init_suite(self, _cmd, prefs_domain(suite));
}
static void groups_add_suite_named(id self, SEL _cmd, NSString *suite) {
    original_add_suite(self, _cmd, prefs_domain(suite));
}
static void groups_remove_suite_named(id self, SEL _cmd, NSString *suite) {
    original_remove_suite(self, _cmd, prefs_domain(suite));
}
static NSDictionary *groups_persistent_domain(id self, SEL _cmd, NSString *name) {
    return original_get_domain(self, _cmd, prefs_domain(name));
}
static void groups_set_persistent_domain(id self, SEL _cmd, NSDictionary *domain, NSString *name) {
    original_set_domain(self, _cmd, domain, prefs_domain(name));
}
static void groups_remove_persistent_domain(id self, SEL _cmd, NSString *name) {
    original_remove_domain(self, _cmd, prefs_domain(name));
}

static IMP swap(Class c, SEL sel, IMP replacement) {
    Method m = class_getInstanceMethod(c, sel);
    if (m == NULL) {
        NSLog(@"ipagroups: %@ has no %@", c, NSStringFromSelector(sel));
        return NULL;
    }
    return method_setImplementation(m, replacement);
}

static void redirect_group_preferences(void) {
    signed_groups = [NSSet setWithArray:groups_in_signature()];
    if (signed_groups.count == 0) return;
    Class d = [NSUserDefaults class];
    original_init_suite = (suite_init_fn)swap(d, @selector(initWithSuiteName:), (IMP)groups_init_suite);
    original_add_suite = (suite_fn)swap(d, @selector(addSuiteNamed:), (IMP)groups_add_suite_named);
    original_remove_suite = (suite_fn)swap(d, @selector(removeSuiteNamed:), (IMP)groups_remove_suite_named);
    original_get_domain = (domain_get_fn)swap(d, @selector(persistentDomainForName:), (IMP)groups_persistent_domain);
    original_set_domain = (domain_set_fn)swap(d, @selector(setPersistentDomain:forName:), (IMP)groups_set_persistent_domain);
    original_remove_domain = (suite_fn)swap(d, @selector(removePersistentDomainForName:), (IMP)groups_remove_persistent_domain);
}

__attribute__((constructor)) static void ipagroups_install(void) {
    Method m = class_getInstanceMethod([NSFileManager class],
                                       @selector(containerURLForSecurityApplicationGroupIdentifier:));
    if (m == NULL) {
        NSLog(@"ipagroups: NSFileManager has no containerURLForSecurityApplicationGroupIdentifier:");
        return;
    }
    // Sandboxed, NSHomeDirectory() is ~/Library/Containers/<bundle id>/Data;
    // the passwd entry still names the real home.
    struct passwd *pw = getpwuid(getuid());
    if (pw == NULL || pw->pw_dir == NULL) {
        NSLog(@"ipagroups: no home directory for uid %d", (int)getuid());
        return;
    }
    real_group_containers = [[NSString stringWithUTF8String:pw->pw_dir]
                             stringByAppendingPathComponent:@"Library/Group Containers/"];
    real_group_containers = [real_group_containers stringByAppendingString:@"/"];
    own_group_containers = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Group Containers"];
    created = [NSMutableSet set];
    original_container_url = (NSURL *(*)(id, SEL, NSString *))method_setImplementation(m, (IMP)own_container_url);
    redirect_group_preferences();
}
