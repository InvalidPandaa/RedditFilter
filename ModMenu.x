// ModMenu.x
//
// Opens the RedditFilter settings with a long press on the menu button
// (the three lines, top right) of the profile screen.

#import <objc/runtime.h>
#import "FeedFilterSettingsViewController.h"

// Reddit's top bar buttons (search, share, menu, ...) are all this class.
@interface RPLTopAppBarButton : UIControl
@end

// The buttons differ only by their icon; the menu button shows "rpl3/menu".
static BOOL RFIsMenuButton(UIView *button) {
  for (UIView *subview in button.subviews) {
    if (![subview isKindOfClass:UIImageView.class]) continue;
    UIImage *image = ((UIImageView *)subview).image;
    if (!image) continue;
    NSString *name = nil;
    @try {
      name = [image.imageAsset valueForKey:@"assetName"];
    } @catch (__unused NSException *e) {
    }
    if ([name isKindOfClass:NSString.class] && [name.lastPathComponent isEqualToString:@"menu"]) return YES;
    if ([image.description containsString:@"/menu\""]) return YES; // if the asset name is unavailable
  }
  return NO;
}

static UINavigationController *RFNavigationController(UIView *view) {
  for (UIResponder *responder = view; responder; responder = responder.nextResponder)
    if ([responder isKindOfClass:UINavigationController.class]) return (UINavigationController *)responder;
  return nil;
}

@interface RFMenuLongPress : NSObject <UIGestureRecognizerDelegate>
@end

@implementation RFMenuLongPress

+ (instancetype)shared {
  static RFMenuLongPress *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [RFMenuLongPress new]; });
  return shared;
}

// Every top bar button gets the recognizer, but it only starts on the profile
// screen's menu button. Everywhere else the buttons behave as before.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
  if (!RFIsMenuButton(recognizer.view)) return NO;
  UIViewController *screen = RFNavigationController(recognizer.view).topViewController;
  return screen && strstr(class_getName(screen.class), "Profile") != NULL;
}

- (void)pressed:(UILongPressGestureRecognizer *)recognizer {
  if (recognizer.state != UIGestureRecognizerStateBegan) return;
  UINavigationController *navigation = RFNavigationController(recognizer.view);
  if (!navigation) return;
  [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
  FeedFilterSettingsViewController *settings =
      [(FeedFilterSettingsViewController *)[objc_getClass("FeedFilterSettingsViewController") alloc]
          initWithStyle:UITableViewStyleGrouped];
  settings.hidesBottomBarWhenPushed = YES;
  [navigation pushViewController:settings animated:YES];
}

@end

%group TopBar

%hook RPLTopAppBarButton
- (void)didMoveToWindow {
  %orig;
  UIView *button = (UIView *)self;
  if (!button.window || objc_getAssociatedObject(button, @selector(pressed:))) return;
  RFMenuLongPress *handler = RFMenuLongPress.shared;
  UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:handler
                                                                                      action:@selector(pressed:)];
  press.delegate = handler;
  [button addGestureRecognizer:press];
  objc_setAssociatedObject(button, @selector(pressed:), press, OBJC_ASSOCIATION_ASSIGN);
}
%end

%end

%ctor {
  Class buttonClass = objc_getClass("RPLComponents.RPLTopAppBarButton");
  if (buttonClass) %init(TopBar, RPLTopAppBarButton = buttonClass);
}
