// BrowserLogin.x
//
// Logs in through reddit.com in a web view instead of through the app's own
// login requests. Reddit's servers refuse the app's login
// (/auth/v2/login/password answers 401) on some networks, because a re-signed
// app has no valid App Attest proof; the website has no such check.
//
// The app reads the cookie `reddit_session` from the answer to its login
// request and exchanges it for a token (/auth/v2/oauth/access-token/session).
// So: when the app sends a login request, a web view with reddit.com/login is
// shown (email, Google, Apple and two-factor all work there), and the cookie
// from that login is handed to the app as the answer to its request.
//
// Switch off with RF_NO_BROWSER_LOGIN=1 in the environment.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <os/log.h>

static NSString *const RFSessionCookieName = @"reddit_session";

static os_log_t RFBLLog(void) {
  static os_log_t log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ log = os_log_create("com.redditfilter", "browserlogin"); });
  return log;
}

#pragma mark - Web view

typedef void (^RFBrowserLoginCompletion)(NSArray<NSHTTPCookie *> *cookies);

@interface RFBrowserLoginController : UIViewController <WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, copy) RFBrowserLoginCompletion completion;
@end

@implementation RFBrowserLoginController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Reddit";
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                    target:self
                                                    action:@selector(cancel)];

  WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
  // Never reuse an earlier web session: its cookie would log in without asking.
  configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
  self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
  self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.webView.navigationDelegate = self;
  self.webView.UIDelegate = self;
  // Google refuses sign-in from embedded web views that don't look like Safari.
  self.webView.customUserAgent =
      @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
      @"(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
  [self.view addSubview:self.webView];
  [configuration.websiteDataStore.httpCookieStore addObserver:self];
  [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://www.reddit.com/login/"]]];
}

- (void)finishWithCookies:(NSArray<NSHTTPCookie *> *)cookies {
  RFBrowserLoginCompletion completion = self.completion;
  if (!completion) return;
  self.completion = nil;
  [self.webView.configuration.websiteDataStore.httpCookieStore removeObserver:self];
  [self dismissViewControllerAnimated:YES completion:^{ completion(cookies); }];
}

- (void)cancel {
  [self finishWithCookies:nil];
}

- (void)checkCookies {
  if (!self.completion) return;
  [self.webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
    for (NSHTTPCookie *cookie in cookies)
      if ([cookie.name isEqualToString:RFSessionCookieName] && [cookie.domain hasSuffix:@"reddit.com"] &&
          cookie.value.length) {
        [self finishWithCookies:cookies];
        return;
      }
  }];
}

- (void)cookiesDidChangeInCookieStore:(WKHTTPCookieStore *)cookieStore {
  [self checkCookies];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  [self checkCookies];
}

// Sign-in with Google or Apple opens a pop-up window; show it in the same view.
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
  if (!navigationAction.targetFrame.isMainFrame) [webView loadRequest:navigationAction.request];
  return nil;
}

@end

#pragma mark - Presenting

static UIViewController *RFTopViewController(void) {
  UIWindow *window = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive)
      continue;
    for (UIWindow *candidate in ((UIWindowScene *)scene).windows)
      if (candidate.isKeyWindow) window = candidate;
  }
  UIViewController *controller = window.rootViewController;
  while (controller.presentedViewController) controller = controller.presentedViewController;
  return controller;
}

static NSMutableArray<RFBrowserLoginCompletion> *RFWaiting;
static BOOL RFLoginShown;

// All login requests that arrive while the web view is open wait for the same login.
static void RFRunBrowserLogin(RFBrowserLoginCompletion completion) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!RFWaiting) RFWaiting = [NSMutableArray array];
    [RFWaiting addObject:completion];
    if (RFLoginShown) return;

    UIViewController *top = RFTopViewController();
    if (!top) {
      os_log(RFBLLog(), "no view controller to present the login on");
      NSArray *waiting = [RFWaiting copy];
      [RFWaiting removeAllObjects];
      for (RFBrowserLoginCompletion done in waiting) done(nil);
      return;
    }
    RFLoginShown = YES;
    RFBrowserLoginController *login = [RFBrowserLoginController new];
    login.completion = ^(NSArray<NSHTTPCookie *> *cookies) {
      RFLoginShown = NO;
      os_log(RFBLLog(), "web login finished, cookies=%lu", (unsigned long)cookies.count);
      NSArray *waiting = [RFWaiting copy];
      [RFWaiting removeAllObjects];
      for (RFBrowserLoginCompletion done in waiting) done(cookies);
    };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:login];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [top presentViewController:navigation animated:YES completion:nil];
  });
}

#pragma mark - Login request

@interface RFLoginProtocol : NSURLProtocol
@end

@implementation RFLoginProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
  NSURL *url = request.URL;
  return [url.host hasSuffix:@"reddit.com"] && [url.path hasPrefix:@"/auth/v2/login/"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
  return request;
}

- (void)startLoading {
  NSURLRequest *request = self.request;
  os_log(RFBLLog(), "login request %{public}@, showing web login", request.URL.path);
  RFRunBrowserLogin(^(NSArray<NSHTTPCookie *> *cookies) {
    if (!cookies.count) {
      [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                         code:NSURLErrorCancelled
                                                                     userInfo:nil]];
      return;
    }

    // The session cookie goes into the answer, where the app looks for it; the
    // other reddit.com cookies go into the shared cookie storage.
    NSMutableArray<NSString *> *setCookies = [NSMutableArray array];
    for (NSHTTPCookie *cookie in cookies) {
      if (![cookie.domain hasSuffix:@"reddit.com"]) continue;
      [NSHTTPCookieStorage.sharedHTTPCookieStorage setCookie:cookie];
      if (![cookie.name isEqualToString:RFSessionCookieName]) continue;
      [setCookies addObject:[NSString stringWithFormat:@"%@=%@; Domain=%@; Path=/; Secure; HttpOnly",
                                                       cookie.name, cookie.value, cookie.domain]];
    }

    NSDictionary *headers = @{
      @"Content-Type" : @"application/json",
      @"Set-Cookie" : [setCookies componentsJoinedByString:@", "],
    };
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
  });
}

- (void)stopLoading {
}

@end

#pragma mark - Install into the app's sessions

// The app builds its own sessions from custom configurations, which don't
// consult classes registered with +registerClass:, so the protocol is added to
// every configuration a session is created with.
static NSURLSessionConfiguration *RFConfigurationWithLogin(NSURLSessionConfiguration *configuration) {
  if (!configuration || [configuration.protocolClasses containsObject:RFLoginProtocol.class]) return configuration;
  NSURLSessionConfiguration *copy = [configuration copy];
  copy.protocolClasses = [@[ RFLoginProtocol.class ] arrayByAddingObjectsFromArray:configuration.protocolClasses ?: @[]];
  return copy;
}

%hook NSURLSession

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
  return %orig(RFConfigurationWithLogin(configuration));
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                  delegate:(id<NSURLSessionDelegate>)delegate
                             delegateQueue:(NSOperationQueue *)queue {
  return %orig(RFConfigurationWithLogin(configuration), delegate, queue);
}

%end

%ctor {
  if (getenv("RF_NO_BROWSER_LOGIN")) return;
  [NSURLProtocol registerClass:RFLoginProtocol.class];
  %init;
}
