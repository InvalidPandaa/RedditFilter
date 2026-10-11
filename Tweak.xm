#import <Comment.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DebugMenu.h"
#import "JSONFilter.h"
#import "Preferences.h"
#import "Redgifs.h"

#pragma mark - Preferences

// Cached copy of the settings, read by the network hook on background threads.
static RFPrefs globalPrefs;
static BOOL noTranslations;

extern "C" void RFReloadPreferences(void) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  RFPrefs prefs;
  prefs.promoted = [defaults boolForKey:kRedditFilterPromoted];
  prefs.recommended = [defaults boolForKey:kRedditFilterRecommended];
  prefs.nsfw = [defaults boolForKey:kRedditFilterNSFW];
  prefs.awards = [defaults boolForKey:kRedditFilterAwards];
  prefs.scores = [defaults boolForKey:kRedditFilterScores];
  prefs.automod = [defaults boolForKey:kRedditFilterAutoCollapseAutoMod];
  prefs.classicViewer = [defaults boolForKey:kRedditFilterClassicViewer];
  prefs.redgifsSound = [defaults boolForKey:kRedditFilterRedgifsSound];
  globalPrefs = prefs;
  noTranslations = [defaults boolForKey:kRedditFilterNoTranslations];
}

#pragma mark - Helpers shared with the settings screen

extern "C" Class CoreClass(NSString *name) {
  Class cls = NSClassFromString(name);
  for (NSString *prefix in @[ @"Reddit.", @"RedditCore.", @"RedditCoreModels.", @"RedditCore_RedditCoreModels.",
                              @"RedditUI.", @"Palette_RedditPalette." ]) {
    if (cls) break;
    cls = NSClassFromString([prefix stringByAppendingString:name]);
  }
  return cls;
}

@interface CUICatalog : NSObject
- (NSArray<NSString *> *)allImageNames;
- (instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle error:(NSError **)error;
@end

// Every bundle in the app that can hold icons. Built the first time an icon is
// needed (when the settings screen opens) instead of on every app launch.
static NSArray<NSBundle *> *RFAssetBundles(void) {
  static NSArray *bundles;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableArray *found = [NSMutableArray arrayWithObject:NSBundle.mainBundle];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *appPath = NSBundle.mainBundle.bundlePath;
    NSString *frameworksPath = [appPath stringByAppendingPathComponent:@"Frameworks"];
    NSMutableArray *dirs = [NSMutableArray arrayWithObject:appPath];
    for (NSString *file in [fm contentsOfDirectoryAtPath:frameworksPath error:nil])
      if ([file hasSuffix:@".framework"]) [dirs addObject:[frameworksPath stringByAppendingPathComponent:file]];
    for (NSString *dir in dirs) {
      if (dir != appPath) {
        NSBundle *framework = [NSBundle bundleWithPath:dir];
        if (framework) [found addObject:framework];
      }
      for (NSString *file in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if (![file hasSuffix:@".bundle"]) continue;
        NSBundle *bundle = [NSBundle bundleWithPath:[dir stringByAppendingPathComponent:file]];
        if (bundle) [found addObject:bundle];
      }
    }
    bundles = found;
  });
  return bundles;
}

static NSArray<CUICatalog *> *RFAssetCatalogs(void) {
  static NSArray *catalogs;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableArray *found = [NSMutableArray array];
    Class catalogClass = objc_getClass("CUICatalog");
    for (NSBundle *bundle in RFAssetBundles()) {
      NSError *error = nil;
      CUICatalog *catalog = [[catalogClass alloc] initWithName:@"Assets" fromBundle:bundle error:&error];
      if (catalog && !error) [found addObject:catalog];
    }
    catalogs = found;
  });
  return catalogs;
}

static UIImage *RFFindIcon(NSString *iconName) {
  for (NSBundle *bundle in RFAssetBundles()) {
    UIImage *image = [UIImage imageNamed:iconName inBundle:bundle compatibleWithTraitCollection:nil];
    if (image) return image;
  }
  // Fallback: search the private asset catalogs for a name like "icon_tag" or "icon_tag_20".
  for (CUICatalog *catalog in RFAssetCatalogs()) {
    Ivar bundleIvar = class_getInstanceVariable(object_getClass(catalog), "_bundle");
    NSBundle *bundle = bundleIvar ? object_getIvar(catalog, bundleIvar) : nil;
    if (!bundle) continue;
    for (NSString *imageName in [catalog allImageNames]) {
      if (![imageName hasPrefix:iconName] ||
          (imageName.length != iconName.length && imageName.length != iconName.length + 3))
        continue;
      UIImage *image = [UIImage imageNamed:imageName inBundle:bundle compatibleWithTraitCollection:nil];
      if (image) return image;
    }
  }
  return nil;
}

extern "C" UIImage *iconWithName(NSString *iconName) {
  if (!iconName) return nil;
  static NSCache *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [NSCache new]; });
  id cached = [cache objectForKey:iconName];
  if (cached) return cached == NSNull.null ? nil : cached;
  UIImage *image = RFFindIcon(iconName);
  [cache setObject:(image ?: NSNull.null) forKey:iconName]; // remember misses too
  return image;
}

#pragma mark - Network filtering

// Reddit tells its servers with this header whether it wants posts and
// comments machine-translated ("enabled" or "disabled").
static NSString *const kTranslationsHeader = @"X-Reddit-Translations";

static NSURLRequest *RFRequestWithoutTranslations(NSURLRequest *request) {
  if (!noTranslations || ![[request valueForHTTPHeaderField:kTranslationsHeader] isEqualToString:@"enabled"])
    return request;
  NSMutableURLRequest *changed = [request mutableCopy];
  [changed setValue:@"disabled" forHTTPHeaderField:kTranslationsHeader];
  return changed;
}

#if REDDITFILTER_DEBUG
// Debug builds only: launch with RF_DUMP_OP=<operation name> to save that
// operation's latest response to tmp/rf-<operation name>.json in the app's
// container. Responses can contain personal data; don't share the file blindly.
static void RFDumpResponse(NSString *operation, NSData *data) {
  const char *wanted = getenv("RF_DUMP_OP");
  if (!wanted || ![operation isEqualToString:@(wanted)]) return;
  NSString *name = [NSString stringWithFormat:@"rf-%@.json", operation];
  [data writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:name] atomically:YES];
}

// Debug builds only: launch with RF_DUMP_MATCH=<word> to save the latest
// response of every operation whose body contains that word, as
// tmp/rf-match-<operation name>.json. Finds the operation that carries a field.
static void RFDumpMatching(NSString *operation, NSData *data) {
  const char *word = getenv("RF_DUMP_MATCH");
  if (!word) return;
  NSData *needle = [NSData dataWithBytes:word length:strlen(word)];
  if ([data rangeOfData:needle options:0 range:NSMakeRange(0, data.length)].location == NSNotFound) return;
  NSString *name = [NSString stringWithFormat:@"rf-match-%@.json", operation ?: @"unknown"];
  [data writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:name] atomically:YES];
}

// Debug builds only: launch with RF_DROP_EXP=<a,b,...> to remove every
// experiment whose name contains one of these words from Reddit's experiment
// list, to find out which experiment switches a feature on.
static NSData *RFDropExperiments(NSString *operation, NSData *data) {
  const char *words = getenv("RF_DROP_EXP");
  if (!words || ![operation isEqualToString:@"GetAllExperimentVariants"]) return data;
  NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                              options:NSJSONReadingMutableContainers
                                                                error:NULL];
  NSMutableArray *variants = json[@"data"][@"experimentVariants"];
  if (![variants isKindOfClass:NSMutableArray.class]) return data;
  NSArray *dropped = [@(words) componentsSeparatedByString:@","];
  for (NSInteger i = variants.count - 1; i >= 0; i--) {
    NSString *name = variants[i][@"experimentName"];
    for (NSString *word in dropped)
      if ([name isKindOfClass:NSString.class] && [name containsString:word]) {
        [variants removeObjectAtIndex:i];
        break;
      }
  }
  return [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] ?: data;
}
#endif

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
  return %orig(RFRequestWithoutTranslations(request));
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response,
                                                        NSError *error))completionHandler {
  request = RFRequestWithoutTranslations(request);
  NSString *host = request.URL.host;
  if (!completionHandler || !RFPrefsAnyEnabled(globalPrefs) ||
      !([host hasPrefix:@"gql"] || [host hasPrefix:@"oauth"]))
    return %orig(request, completionHandler);

  void (^filteringHandler)(NSData *, NSURLResponse *, NSError *) =
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data.length) {
#if REDDITFILTER_DEBUG
          RFDumpResponse(RFOperationName(request), data);
          RFDumpMatching(RFOperationName(request), data);
          data = RFDropExperiments(RFOperationName(request), data);
#endif
          NSData *filtered = RFFilteredResponseData(data, RFOperationName(request), globalPrefs);
          if (filtered) data = filtered;
        }
        completionHandler(data, response, error);
      };
  return %orig(request, filteringHandler);
}
%end

#pragma mark - Swift model and UI hooks

%group SwiftClasses

%hook Post
- (NSArray *)awardingTotals {
  return globalPrefs.awards ? nil : %orig;
}
- (NSUInteger)totalAwardsReceived {
  return globalPrefs.awards ? 0 : %orig;
}
- (BOOL)canAward {
  return globalPrefs.awards ? NO : %orig;
}
- (BOOL)isScoreHidden {
  return globalPrefs.scores ? YES : %orig;
}
%end

%hook Comment
- (NSArray *)awardingTotals {
  return globalPrefs.awards ? nil : %orig;
}
- (NSUInteger)totalAwardsReceived {
  return globalPrefs.awards ? 0 : %orig;
}
- (BOOL)canAward {
  return globalPrefs.awards ? NO : %orig;
}
- (BOOL)isScoreHidden {
  return globalPrefs.scores ? YES : %orig;
}
- (BOOL)shouldAutoCollapse {
  return (globalPrefs.automod && [((Comment *)self).authorPk isEqualToString:@"t2_6l4z3"]) ? YES : %orig;
}
%end

%end

%ctor {
  [NSUserDefaults.standardUserDefaults registerDefaults:@{
    kRedditFilterPromoted : @YES,
    kRedditFilterRecommended : @NO,
    kRedditFilterNSFW : @NO,
    kRedditFilterAwards : @NO,
    kRedditFilterScores : @NO,
    kRedditFilterAutoCollapseAutoMod : @NO,
    kRedditFilterNoTranslations : @NO,
    kRedditFilterClassicViewer : @NO,
    kRedditFilterRedgifsSound : @NO,
    kRedditFilterHideDrawerGames : @NO,
    kRedditFilterHideDrawerResources : @NO,
    kRedditFilterHideDrawerRedditPro : @NO,
  }];
  RFReloadPreferences();
  RFSetRedgifsResolver(^(NSSet<NSString *> *ids) { return RFPlayableRedgifs(ids); });

#if REDDITFILTER_DEBUG
  // Debug builds only: launch with RF_NO_FILTER=1 to run the app without any filter hooks.
  if (getenv("RF_NO_FILTER")) return;
#endif
  %init;
  %init(SwiftClasses, Post = CoreClass(@"Post"), Comment = CoreClass(@"Comment"));
}
