// Per-app workarounds for an app's own code that misbehaves under Mac
// Catalyst, applied from a table instead of written per app.
//
// Why a table: the first workaround (YouTube's blank window, 2026-11-26) was
// one getter forced to YES, and the next app needing the same kind of fix
// should need one row, not a new shim. The rows live in Eider
// (Sources/EiderKit/Engine/AppQuirks.swift, which records why each exists);
// the installer links this library only into an app whose shipped bundle id
// has a row, and writes that app's rows into the bundle as EiderQuirks.plist
// before signing, so the signature seals them.
//
// What: for each row {class, selector, returns}, the instance method
// -[class selector] answers `returns` instead of running. A row is skipped,
// with a log line, when the class or the method is missing (an app version
// without them is left alone) or the method is not a BOOL getter with no
// arguments (type encoding "B16@0:8" on arm64), so a stale row can never
// replace a method of another shape. The classes must be in an image loaded
// at launch: this constructor runs before main, after the Objective-C runtime
// has registered every class of the images dyld loaded.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static BOOL answer_yes(id self, SEL _cmd) { return YES; }
static BOOL answer_no(id self, SEL _cmd) { return NO; }

static NSString *string_in(NSDictionary *row, NSString *key) {
    id value = row[key];
    return [value isKindOfClass:[NSString class]] && [value length] > 0 ? value : nil;
}

// Make -[cls sel] (a BOOL getter) answer `value`; a reason when it cannot.
static NSString *force_bool(NSString *cls, NSString *sel, BOOL value) {
    Class c = NSClassFromString(cls);
    if (c == Nil) return @"no such class";
    Method m = class_getInstanceMethod(c, NSSelectorFromString(sel));
    if (m == NULL) return @"no such method";
    if (strcmp(method_getTypeEncoding(m), "B16@0:8") != 0) return @"not a BOOL getter";
    method_setImplementation(m, value ? (IMP)answer_yes : (IMP)answer_no);
    return nil;
}

__attribute__((constructor)) static void ipaquirks_install(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    NSString *path = [NSBundle.mainBundle pathForResource:@"EiderQuirks" ofType:@"plist"];
    NSArray *rows = path ? [NSArray arrayWithContentsOfFile:path] : nil;
    if (![rows isKindOfClass:[NSArray class]]) {
        NSLog(@"ipaquirks: %@ has no readable EiderQuirks.plist; nothing applied", bundle);
        return;
    }
    for (NSDictionary *row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        NSString *cls = string_in(row, @"class"), *sel = string_in(row, @"selector");
        id returns = row[@"returns"];
        if (cls == nil || sel == nil || ![returns isKindOfClass:[NSNumber class]]) {
            NSLog(@"ipaquirks: %@ skipped a malformed row", bundle);
            continue;
        }
        NSString *refused = force_bool(cls, sel, [returns boolValue]);
        if (refused) NSLog(@"ipaquirks: %@ -[%@ %@] left as it is: %@", bundle, cls, sel, refused);
        else NSLog(@"ipaquirks: %@ -[%@ %@] answers %@", bundle, cls, sel, [returns boolValue] ? @"YES" : @"NO");
    }
}
