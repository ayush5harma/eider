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
// What: answer containerURLForSecurityApplicationGroupIdentifier: with a
// directory inside the app's OWN sandbox container
// (~/Library/Containers/<bundle id>/Data/Library/Group Containers/<group>),
// created on first use. The app keeps one private copy of each group's data;
// nothing is shared with any other app, which is the point of the sandbox.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSURL *(*original_container_url)(id, SEL, NSString *);

static BOOL is_plain_group_id(NSString *group) {
    if (group.length == 0 || group.length > 255) return NO;
    if ([group containsString:@"/"] || [group containsString:@".."]) return NO;
    return YES;
}

static NSURL *own_container_url(id self, SEL _cmd, NSString *group) {
    if (!is_plain_group_id(group)) return original_container_url(self, _cmd, group);
    // Sandboxed, NSHomeDirectory() is ~/Library/Containers/<bundle id>/Data.
    NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Group Containers"]
                      stringByAppendingPathComponent:group];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path
                                   withIntermediateDirectories:YES
                                                    attributes:@{NSFilePosixPermissions: @0700}
                                                         error:&error]) {
        NSLog(@"ipagroups: could not create %@: %@", path, error);
        return original_container_url(self, _cmd, group);
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
    original_container_url = (NSURL *(*)(id, SEL, NSString *))method_setImplementation(m, (IMP)own_container_url);
}
