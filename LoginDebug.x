// LoginDebug.x
//
// Diagnostics for the sideload login problem. Only compiled into builds made
// with DEBUG_MENU=1. Nothing here changes what the app does; it only logs:
//
//   * the bundle ID the app really runs under vs. the one it reports,
//   * every App Attest call (DCAppAttestService) and how it ended,
//   * every auth / attestation / reCAPTCHA request with its HTTP status.
//
// Read the output in Console.app (device connected, filter: subsystem
// "com.redditfilter.debug") or with:
//   log stream --predicate 'subsystem == "com.redditfilter.debug"'
//
// Request and response bodies and header values are never logged, so the log
// contains no passwords or tokens and is safe to share.

#import "DebugMenu.h"

#if REDDITFILTER_DEBUG

#import <DeviceCheck/DeviceCheck.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

static os_log_t RFLog(void) {
  static os_log_t log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ log = os_log_create("com.redditfilter.debug", "login"); });
  return log;
}

#define RFDLog(fmt, ...) os_log(RFLog(), "%{public}@", [NSString stringWithFormat:fmt, ##__VA_ARGS__])

static NSString *RFErr(NSError *error) {
  return error ? [NSString stringWithFormat:@"%@ %ld", error.domain, (long)error.code] : @"ok";
}

#pragma mark - App Attest

%hook DCAppAttestService

- (BOOL)isSupported {
  BOOL supported = %orig;
  RFDLog(@"[attest] isSupported -> %d", supported);
  return supported;
}

- (void)generateKeyWithCompletionHandler:(void (^)(NSString *keyId, NSError *error))handler {
  RFDLog(@"[attest] generateKey called");
  void (^logged)(NSString *, NSError *) = ^(NSString *keyId, NSError *error) {
    RFDLog(@"[attest] generateKey -> %@", RFErr(error));
    if (handler) handler(keyId, error);
  };
  %orig(logged);
}

- (void)attestKey:(NSString *)keyId
    clientDataHash:(NSData *)hash
 completionHandler:(void (^)(NSData *attestation, NSError *error))handler {
  RFDLog(@"[attest] attestKey called");
  void (^logged)(NSData *, NSError *) = ^(NSData *attestation, NSError *error) {
    RFDLog(@"[attest] attestKey -> %@ (%lu bytes)", RFErr(error), (unsigned long)attestation.length);
    if (handler) handler(attestation, error);
  };
  %orig(keyId, hash, logged);
}

- (void)generateAssertion:(NSString *)keyId
           clientDataHash:(NSData *)hash
        completionHandler:(void (^)(NSData *assertion, NSError *error))handler {
  RFDLog(@"[attest] generateAssertion called");
  void (^logged)(NSData *, NSError *) = ^(NSData *assertion, NSError *error) {
    RFDLog(@"[attest] generateAssertion -> %@ (%lu bytes)", RFErr(error), (unsigned long)assertion.length);
    if (handler) handler(assertion, error);
  };
  %orig(keyId, hash, logged);
}

%end

#pragma mark - Auth-related network requests

static BOOL RFIsInteresting(NSURL *url) {
  NSString *host = url.host.lowercaseString ?: @"";
  NSString *path = url.path.lowercaseString ?: @"";
  if ([host containsString:@"recaptcha"] || [host hasPrefix:@"accounts."]) return YES;
  if (![host hasSuffix:@"reddit.com"]) return NO;
  for (NSString *word in @[ @"attestation", @"login", @"auth", @"token", @"register", @"session" ])
    if ([path containsString:word]) return YES;
  return NO;
}

// Header names only (never values) that hint at attestation or bot checks.
static NSString *RFHeaderNames(NSDictionary *headers) {
  NSMutableArray *names = [NSMutableArray array];
  for (NSString *name in headers) {
    NSString *lower = name.lowercaseString;
    for (NSString *word in @[ @"attest", @"recaptcha", @"device", @"integrity", @"retry" ])
      if ([lower containsString:word]) {
        [names addObject:name];
        break;
      }
  }
  return [names componentsJoinedByString:@","];
}

@interface RFTaskObserver : NSObject
@end

@implementation RFTaskObserver
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(NSURLSessionTask *)task
                        change:(NSDictionary *)change
                       context:(void *)context {
  if (task.state != NSURLSessionTaskStateCompleted) return;
  @try {
    [task removeObserver:self forKeyPath:@"state"];
  } @catch (__unused NSException *e) {
  }
  NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
  NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? response.statusCode : 0;
  NSDictionary *headers = status ? response.allHeaderFields : nil;
  RFDLog(@"[net] <- %ld %@%@ err=%@ respHeaders=[%@]", (long)status, task.originalRequest.URL.host,
         task.originalRequest.URL.path, RFErr(task.error), RFHeaderNames(headers));
  objc_setAssociatedObject(task, @selector(observeValueForKeyPath:ofObject:change:context:), nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

%hook NSURLSessionTask

- (void)resume {
  NSURLRequest *request = self.originalRequest;
  SEL key = @selector(observeValueForKeyPath:ofObject:change:context:);
  if (request && RFIsInteresting(request.URL) && !objc_getAssociatedObject(self, key)) {
    RFDLog(@"[net] -> %@ %@%@ reqHeaders=[%@]", request.HTTPMethod, request.URL.host, request.URL.path,
           RFHeaderNames(request.allHTTPHeaderFields));
    RFTaskObserver *observer = [RFTaskObserver new];
    objc_setAssociatedObject(self, key, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self addObserver:observer forKeyPath:@"state" options:0 context:NULL];
  }
  %orig;
}

%end

#pragma mark - Startup report

%ctor {
  %init;
  // The Info.plist on disk is what the installer (SideStore) wrote; the
  // NSBundle getters are what RedditSideloadFix makes the app believe.
  NSString *plistPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Info.plist"];
  NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:plistPath];
  CFStringRef cfId = CFBundleGetIdentifier(CFBundleGetMainBundle());
  RFDLog(@"[boot] bundle id on disk=%@ NSBundle=%@ CFBundle=%@ infoDictionary=%@", onDisk[@"CFBundleIdentifier"],
         NSBundle.mainBundle.bundleIdentifier, (__bridge NSString *)cfId,
         NSBundle.mainBundle.infoDictionary[@"CFBundleIdentifier"]);
  RFDLog(@"[boot] app %@ (%@), iOS %@", onDisk[@"CFBundleShortVersionString"], onDisk[@"CFBundleVersion"],
         NSProcessInfo.processInfo.operatingSystemVersionString);
}

#endif // REDDITFILTER_DEBUG
