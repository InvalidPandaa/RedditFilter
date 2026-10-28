#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import "fishhook/fishhook.h"

#define BUNDLE_NAME @"Reddit"
#define BUNDLE_ID @"com.reddit.Reddit"
#define TEAM_ID @"2TDUX39LX8"

// https://github.com/opa334/IGSideloadFix

static NSString *keychainAccessGroup;
static NSString *originalKeychainAccessGroup;
static NSURL *fakeGroupContainerURL;

static void createDirectoryIfNotExists(NSURL *URL) {
  if (![URL checkResourceIsReachableAndReturnError:nil]) {
    [[NSFileManager defaultManager] createDirectoryAtURL:URL
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
  }
}

%hook NSBundle

- (NSString *)bundleIdentifier {
  NSArray <NSNumber *>*addresses = NSThread.callStackReturnAddresses;
  Dl_info info;
  if (addresses.count < 3) return %orig;
  if (dladdr((void *)[addresses[2] longLongValue], &info) == 0 || !info.dli_fname) return %orig;
  NSString *path = [NSString stringWithUTF8String:info.dli_fname];
  if ([path hasPrefix:NSBundle.mainBundle.bundlePath]) return BUNDLE_ID;
  return %orig;
}

- (id)objectForInfoDictionaryKey:(NSString *)key {
  if ([key isEqualToString:@"CFBundleIdentifier"]) return BUNDLE_ID;
  if ([key isEqualToString:@"CFBundleDisplayName"] || [key isEqualToString:@"CFBundleName"])
    return BUNDLE_NAME;
  return %orig;
}

%end

%group SideloadedFixes

%hook NSFileManager

- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
  NSURL *fakeURL = [fakeGroupContainerURL URLByAppendingPathComponent:groupIdentifier];

  createDirectoryIfNotExists(fakeURL);
  createDirectoryIfNotExists([fakeURL URLByAppendingPathComponent:@"Library"]);
  createDirectoryIfNotExists([fakeURL URLByAppendingPathComponent:@"Library/Caches"]);

  return fakeURL;
}

%end

// App Attest proves to Reddit's servers which app is running, and the proof
// names the team that signed it. A re-signed app gets a valid proof for the
// wrong team: Reddit rejects it (register_device answers 400) and then refuses
// the login (401). Where App Attest is unavailable, as in the simulator, the
// app signs in without it, so it is reported as unavailable here.
%hook DCAppAttestService
- (BOOL)isSupported {
  return NO;
}
%end

static void loadKeychainAccessGroup() {
  NSDictionary *dummyItem = @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrAccount : @"dummyItem",
    (__bridge id)kSecAttrService : @"dummyService",
    (__bridge id)kSecReturnAttributes : @YES,
  };

  CFTypeRef result = NULL;
  OSStatus ret = SecItemCopyMatching((__bridge CFDictionaryRef)dummyItem, &result);
  if (ret == errSecItemNotFound) ret = SecItemAdd((__bridge CFDictionaryRef)dummyItem, &result);

  if (ret == errSecSuccess && result) {
    NSDictionary *resultDict = (__bridge id)result;
    keychainAccessGroup = resultDict[(__bridge id)kSecAttrAccessGroup];
    originalKeychainAccessGroup =
        [keychainAccessGroup stringByReplacingCharactersInRange:NSMakeRange(0, 10)
                                                     withString:TEAM_ID];
    NSLog(@"loaded keychainAccessGroup: %@", keychainAccessGroup);
  }

  if (result) CFRelease(result);
}

%end

// DeviceCheck tokens are bound to the signing team as well. The reCAPTCHA SDK
// sends one with the login; from a re-signed app it fails Google's check and
// lowers the risk score. Reddit lets a low score through from mobile carrier
// addresses but not from a home Wi-Fi address, which is why login only worked
// over mobile data. Without DeviceCheck (as in the simulator) reCAPTCHA scores
// the device without it. Can be switched off in the settings ("Login fix").
%group DeviceCheckFix

%hook DCDevice
- (BOOL)isSupported {
  return NO;
}

- (void)generateTokenWithCompletionHandler:(void (^)(NSData *token, NSError *error))completion {
  // DCErrorDomain / DCErrorFeatureUnsupported, spelled out so the framework need not be linked.
  NSError *error = [NSError errorWithDomain:@"com.apple.devicecheck.error" code:1 userInfo:nil];
  if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
}
%end

%end

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus hook_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
  if (CFDictionaryContainsKey(attributes, kSecAttrAccessGroup)) {
    CFMutableDictionaryRef mutableAttributes =
        CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, attributes);
    CFDictionarySetValue(mutableAttributes, kSecAttrAccessGroup,
                         (__bridge void *)keychainAccessGroup);
    attributes = CFDictionaryCreateCopy(kCFAllocatorDefault, mutableAttributes);
    CFRelease(mutableAttributes);
  }
  OSStatus status = orig_SecItemAdd(attributes, result);
  if (result && *result && CFGetTypeID(*result) == CFDictionaryGetTypeID() &&
      CFDictionaryContainsKey(*result, kSecAttrAccessGroup)) {
    CFMutableDictionaryRef mutableResult =
        CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, *result);
    CFDictionarySetValue(mutableResult, kSecAttrAccessGroup,
                         (__bridge void *)originalKeychainAccessGroup);
    *result = CFDictionaryCreateCopy(kCFAllocatorDefault, mutableResult);
    CFRelease(mutableResult);
  }
  return status;
}

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus hook_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
  if (CFDictionaryContainsKey(query, kSecAttrAccessGroup)) {
    CFMutableDictionaryRef mutableQuery =
        CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    CFDictionarySetValue(mutableQuery, kSecAttrAccessGroup, (__bridge void *)keychainAccessGroup);
    query = CFDictionaryCreateCopy(kCFAllocatorDefault, mutableQuery);
    CFRelease(mutableQuery);
  }
  OSStatus status = orig_SecItemCopyMatching(query, result);
  if (result && *result && CFGetTypeID(*result) == CFDictionaryGetTypeID() &&
      CFDictionaryContainsKey(*result, kSecAttrAccessGroup)) {
    CFMutableDictionaryRef mutableResult =
        CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, *result);
    CFDictionarySetValue(mutableResult, kSecAttrAccessGroup,
                         (__bridge void *)originalKeychainAccessGroup);
    *result = CFDictionaryCreateCopy(kCFAllocatorDefault, mutableResult);
    CFRelease(mutableResult);
  }
  return status;
}

static OSStatus (*orig_SecItemDelete)(CFDictionaryRef);
static OSStatus hook_SecItemDelete(CFDictionaryRef query) {
  if (CFDictionaryContainsKey(query, kSecAttrAccessGroup)) {
    CFMutableDictionaryRef mutableQuery =
        CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    CFDictionarySetValue(mutableQuery, kSecAttrAccessGroup, (__bridge void *)keychainAccessGroup);
    query = CFDictionaryCreateCopy(kCFAllocatorDefault, mutableQuery);
    CFRelease(mutableQuery);
  }
  return orig_SecItemDelete(query);
}

static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus hook_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
  if (CFDictionaryContainsKey(query, kSecAttrAccessGroup)) {
    CFMutableDictionaryRef mutableQuery =
        CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    CFDictionarySetValue(mutableQuery, kSecAttrAccessGroup, (__bridge void *)keychainAccessGroup);
    query = CFDictionaryCreateCopy(kCFAllocatorDefault, mutableQuery);
    CFRelease(mutableQuery);
  }
  return orig_SecItemUpdate(query, attributesToUpdate);
}

static void initSideloadedFixes() {
  fakeGroupContainerURL =
      [NSURL fileURLWithPath:[NSHomeDirectory()
                                 stringByAppendingPathComponent:@"Documents/FakeGroupContainers"]
                 isDirectory:YES];
  loadKeychainAccessGroup();
  // No access group means the keychain is unavailable (e.g. no entitlement, simulator).
  // Rewriting queries would then put NULL into a CFDictionary and crash.
  if (keychainAccessGroup.length > 10) rebind_symbols(
      (struct rebinding[]){
          {"SecItemAdd", (void *)hook_SecItemAdd, (void **)&orig_SecItemAdd},
          {"SecItemCopyMatching", (void *)hook_SecItemCopyMatching,
           (void **)&orig_SecItemCopyMatching},
          {"SecItemDelete", (void *)hook_SecItemDelete, (void **)&orig_SecItemDelete},
          {"SecItemUpdate", (void *)hook_SecItemUpdate, (void **)&orig_SecItemUpdate},
      },
      4);
  %init(SideloadedFixes);
  if (![NSUserDefaults.standardUserDefaults boolForKey:@"kRedditFilterKeepDeviceCheck"]) {
    // Make sure DCDevice exists before hooking it, or the hook would be skipped silently.
    dlopen("/System/Library/Frameworks/DeviceCheck.framework/DeviceCheck", RTLD_LAZY);
    %init(DeviceCheckFix);
  }
}

static NSString *originalBundleIdentifier;

static void recaptcha_hook(id self, SEL _cmd, id arg) {
  Class cls = object_getClass(self);
  SEL orig_name = NSSelectorFromString([@"orig_" stringByAppendingString:NSStringFromSelector(_cmd)]);
  void (*orig_imp)(id, SEL, id);
  Method method = class_getInstanceMethod(cls, orig_name);

  if (!method) {
    method = class_getClassMethod(cls, orig_name);
    if (method) {
      orig_imp = (void (*)(id, SEL, id))method_getImplementation(method);
      orig_imp(self, orig_name, arg);
    }
    // In case there is no method (is this possible? idk)
    return;
  }

  if ([arg isKindOfClass:NSString.class] && [(NSString *)arg isEqualToString:originalBundleIdentifier])
    arg = BUNDLE_ID;

  orig_imp = (void (*)(id, SEL, id))method_getImplementation(method);
  orig_imp(self, orig_name, arg);
}

static BOOL (*orig_class_addMethod)(Class, SEL, IMP, const char *);
static BOOL hook_class_addMethod(Class cls, SEL name, IMP imp, const char *types) {
  if (!types) return orig_class_addMethod(cls, name, imp, types); // system frameworks pass NULL
  NSString *methodEncoding = [@(types) stringByReplacingOccurrencesOfString:@"[0-9]+" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, strlen(types))];
  if ([class_getSuperclass(cls) isEqual:objc_getClass("RCAx_GPBMessage")] && [methodEncoding isEqualToString:@"v@:@"]) {
    if (!orig_class_addMethod(cls, NSSelectorFromString([@"orig_" stringByAppendingString:NSStringFromSelector(name)]), imp, types))
      return orig_class_addMethod(cls, name, imp, types);
    imp = (IMP)recaptcha_hook;
  }

  return orig_class_addMethod(cls, name, imp, types);
}

static void initRecaptchaFix() {
  rebind_symbols((struct rebinding[]){{
    "class_addMethod", (void *)hook_class_addMethod, (void **)&orig_class_addMethod,
  }}, 1);
}

%ctor {
  originalBundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
  %init;
  initSideloadedFixes();
  initRecaptchaFix();
}
