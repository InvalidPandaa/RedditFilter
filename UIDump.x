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
#import <objc/runtime.h>

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

static void RFDumpMethods(NSMutableString *out, Class cls, NSArray<NSString *> *words) {
  for (Class c = cls; c && c != NSObject.class; c = class_getSuperclass(c)) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(c, &count);
    for (unsigned int i = 0; i < count; i++) {
      NSString *name = NSStringFromSelector(method_getName(methods[i]));
      for (NSString *word in words)
        if ([name.lowercaseString containsString:word]) {
          [out appendFormat:@"    -[%@ %@]\n", c, name];
          break;
        }
    }
    free(methods);
  }
}

// A diffable data source keeps its sections in a private Objective-C object.
// Show its instance variables, the section identifiers and the methods that
// apply or edit a snapshot.
static void RFDumpDataSource(NSMutableString *out, id dataSource) {
  for (Class c = [dataSource class]; c && c != NSObject.class; c = class_getSuperclass(c)) {
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(c, &count);
    for (unsigned int i = 0; i < count; i++) {
      const char *type = ivar_getTypeEncoding(ivars[i]);
      [out appendFormat:@"  ivar %@.%s type=%s\n", c, ivar_getName(ivars[i]), type ?: "?"];
      // Swift leaves the type empty; "_impl" is known to hold an object.
      BOOL isObject = (type && type[0] == '@') || !strcmp(ivar_getName(ivars[i]), "_impl");
      if (!isObject) continue;
      id value = object_getIvar(dataSource, ivars[i]);
      [out appendFormat:@"    value class=%@\n", [value class]];
      if (![value respondsToSelector:@selector(snapshot)]) continue;
      id snapshot = [value performSelector:@selector(snapshot)];
      [out appendFormat:@"    snapshot class=%@\n", [snapshot class]];
      if ([snapshot respondsToSelector:@selector(sectionIdentifiers)])
        for (id section in [snapshot performSelector:@selector(sectionIdentifiers)])
          [out appendFormat:@"    section id class=%@ description=%@\n", [section class], section];
      RFDumpMethods(out, [value class], @[ @"apply", @"snapshot" ]);
      RFDumpMethods(out, [snapshot class], @[ @"delete", @"sectionidentifier" ]);
    }
    free(ivars);
  }
}

// Accessibility identifiers are stable, language-independent names, and table
// views show who supplies their rows: both are what a hook needs to latch on to.
static void RFDumpDetails(NSMutableString *out, UIView *view) {
  if (view.accessibilityIdentifier.length)
    [out appendFormat:@"id=%@  %@ frame=%@\n", view.accessibilityIdentifier, view.class,
                      NSStringFromCGRect([view convertRect:view.bounds toView:nil])];
  if ([view isKindOfClass:UITableView.class]) {
    UITableView *table = (UITableView *)view;
    [out appendFormat:@"table %p dataSource=%@ delegate=%@ sections=%ld\n", table, [table.dataSource class],
                      [table.delegate class], (long)table.numberOfSections];
    for (NSString *name in @[
           @"tableView:heightForRowAtIndexPath:", @"tableView:heightForHeaderInSection:",
           @"tableView:viewForHeaderInSection:", @"tableView:heightForFooterInSection:",
           @"tableView:viewForFooterInSection:", @"tableView:titleForHeaderInSection:"
         ])
      [out appendFormat:@"  delegate %@: %d\n", name, [table.delegate respondsToSelector:NSSelectorFromString(name)]];
    RFDumpDataSource(out, table.dataSource);
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
      UIView *header = [table headerViewForSection:section];
      [out appendFormat:@"  section %ld rows=%ld header=%@ headerId=%@\n", (long)section,
                        (long)[table numberOfRowsInSection:section], header.class, header.accessibilityIdentifier];
    }
  }
  for (UIView *subview in view.subviews) RFDumpDetails(out, subview);
}

static void RFDumpUI(void) {
  NSMutableString *out = [NSMutableString string];
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
      [out appendFormat:@"===== WINDOW %@ key=%d =====\n", window.class, window.isKeyWindow];
      RFDumpControllers(out, window.rootViewController, 0);
      [out appendString:@"----- identifiers and tables -----\n"];
      RFDumpDetails(out, window);
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
