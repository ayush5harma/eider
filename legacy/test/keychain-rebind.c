// The probe for test/keychain-rebind.sh: linked against the keychain shim and
// test/rebind-hook.c, it makes each SecItem call once for a class the shim
// passes through (a key) and once for one it answers itself (a generic
// password), and prints what came back. A hook loop never gets to print: the
// hook library exits 3 first.
//
// The key queries name a fresh random tag and the data protection keychain,
// so the real keychain has nothing to match and nothing to change.

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>

void rebind_hook_report(int *slots, int *calls);

static CFMutableDictionaryRef query(CFStringRef cls, CFStringRef unique) {
    CFMutableDictionaryRef q = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(q, kSecClass, cls);
    CFDictionarySetValue(q, kSecUseDataProtectionKeychain, kCFBooleanTrue);
    if (CFEqual(cls, kSecClassKey)) {
        CFDataRef tag = CFStringCreateExternalRepresentation(kCFAllocatorDefault, unique, kCFStringEncodingUTF8, 0);
        CFDictionarySetValue(q, kSecAttrApplicationTag, tag);
        CFRelease(tag);
    } else {
        CFDictionarySetValue(q, kSecAttrService, unique);
    }
    return q;
}

static void run(const char *label, CFStringRef cls, CFStringRef unique) {
    CFMutableDictionaryRef q = query(cls, unique);
    CFTypeRef out = NULL;
    OSStatus copy = SecItemCopyMatching(q, &out);
    if (out) CFRelease(out);
    // No secret and no key: the real keychain refuses it, the shim stores it
    // under the test's own HOME, and the delete below removes it again.
    OSStatus add = SecItemAdd(q, NULL);
    CFDictionaryRef none = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus update = SecItemUpdate(q, none);
    OSStatus del = SecItemDelete(q);
    printf("%s copy=%d add=%d update=%d delete=%d\n", label, (int)copy, (int)add, (int)update, (int)del);
    CFRelease(none);
    CFRelease(q);
}

int main(void) {
    CFUUIDRef u = CFUUIDCreate(kCFAllocatorDefault);
    CFStringRef unique = CFUUIDCreateString(kCFAllocatorDefault, u);
    run("passthrough", kSecClassKey, unique);
    run("shim", kSecClassGenericPassword, unique);
    int slots = 0, calls = 0;
    rebind_hook_report(&slots, &calls);
    printf("hooks slots=%d calls=%d\n", slots, calls);
    CFRelease(unique);
    CFRelease(u);
    return 0;
}
