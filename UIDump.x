// UIDump.x
//
// Debug builds only. The app exits when a debugger attaches, so this is the
// way to look at its view hierarchy: post a Darwin notification and the app
// writes the hierarchy of every window to tmp/rf-ui-dump.txt in its container.
//
//   xcrun simctl spawn booted notifyutil -p com.redditfilter.debug.dump
//   cat "$(xcrun simctl get_app_container booted com.reddit.Reddit data)/tmp/rf-ui-dump.txt"

#import "DebugMenu.h"

#if REDDITFILTER_DEBUG

#import <UIKit/UIKit.h>
#import <notify.h>

@interface UIView (RFDump)
- (NSString *)recursiveDescription;
@end

@interface UIViewController (RFDump)
- (NSString *)_printHierarchy;
@end

static void RFDumpItems(NSMutableString *out, NSString *label, NSArray<UIBarButtonItem *> *items) {
  for (UIBarButtonItem *item in items)
    [out appendFormat:@"    %@: %@ title=%@ ax=%@ id=%@ customView=%@ target=%@ action=%@ menu=%d\n", label,
                      item.class, item.title, item.accessibilityLabel, item.accessibilityIdentifier,
                      item.customView.class, [item.target class], NSStringFromSelector(item.action),
                      item.menu != nil];
}

static void RFDumpControllers(NSMutableString *out, UIViewController *controller, int depth) {
  if (!controller) return;
  [out appendFormat:@"%*s%@ title=%@\n", depth * 2, "", controller.class, controller.title];
  RFDumpItems(out, @"right", controller.navigationItem.rightBarButtonItems);
  RFDumpItems(out, @"left", controller.navigationItem.leftBarButtonItems);
  for (UIViewController *child in controller.childViewControllers) RFDumpControllers(out, child, depth + 1);
  RFDumpControllers(out, controller.presentedViewController, depth + 1);
}

static void RFDumpUI(void) {
  NSMutableString *out = [NSMutableString string];
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
      [out appendFormat:@"===== WINDOW %@ key=%d =====\n", window.class, window.isKeyWindow];
      RFDumpControllers(out, window.rootViewController, 0);
      [out appendFormat:@"----- views -----\n%@\n", [window recursiveDescription]];
    }
  }
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rf-ui-dump.txt"];
  [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

%ctor {
  int token;
  notify_register_dispatch("com.redditfilter.debug.dump", &token, dispatch_get_main_queue(), ^(int t) {
    RFDumpUI();
  });
}

#endif // REDDITFILTER_DEBUG
