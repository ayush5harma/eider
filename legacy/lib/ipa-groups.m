// App-group containers for an ad-hoc signed iOS app on macOS.
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

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <pwd.h>
#include <unistd.h>

static NSURL *(*original_container_url)(id, SEL, NSString *);
static NSString *real_group_containers;   // ~/Library/Group Containers/ of the real home
static NSString *own_group_containers;    // the same folder inside the app's container
static NSMutableSet<NSString *> *created; // groups whose folder exists already

static BOOL is_plain_group_id(NSString *group) {
    if (group.length == 0 || group.length > 255) return NO;
    if ([group hasPrefix:@"."] || [group containsString:@"/"]) return NO;
    return YES;
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
    NSString *path = [own_group_containers stringByAppendingPathComponent:resolved];
    @synchronized (created) {
        if (![created containsObject:resolved]) {
            NSError *error = nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:path
                                           withIntermediateDirectories:YES
                                                            attributes:@{NSFilePosixPermissions: @0700}
                                                                 error:&error]) {
                NSLog(@"ipagroups: could not create %@: %@", path, error);
                return answer;
            }
            [created addObject:resolved];
        }
    }
    return [NSURL fileURLWithPath:path isDirectory:YES];
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
}
