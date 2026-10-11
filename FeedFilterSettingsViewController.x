#import <objc/runtime.h>
#import "FeedFilterSettingsViewController.h"
#import "CacheCleaner.h"
#import "DebugMenu.h"
#import "RFLogo.h"

#ifndef RF_VERSION
#define RF_VERSION "dev" // the Makefile passes the real version
#endif

#pragma mark - The toggle rows

typedef struct {
  __unsafe_unretained NSString *key;
  __unsafe_unretained NSString *title;
  __unsafe_unretained NSString *subtitle; // nil for none
  __unsafe_unretained NSString *symbol;   // SF Symbol name
  BOOL switchOnMeansShow;                 // YES: switch ON shows the content (the saved setting is the opposite)
} RFToggleRow;

static const RFToggleRow kToggleRows[] = {
    {kRedditFilterPromoted, @"Promoted", nil, @"megaphone", YES},
    {kRedditFilterRecommended, @"Recommended", nil, @"sparkles", YES},
    {kRedditFilterNSFW, @"NSFW", nil, @"eye.slash", YES},
    {kRedditFilterAwards, @"Awards", @"Show awards on posts and comments", @"rosette", YES},
    {kRedditFilterScores, @"Scores", @"Show vote count on posts and comments", @"arrow.up", YES},
    {kRedditFilterAutoCollapseAutoMod, @"AutoMod", @"Auto collapse AutoMod comments", @"shield", NO},
    // The rows from here on are shown in the App section.
    {kRedditFilterNoTranslations, @"Translations", @"Let Reddit translate posts and comments", @"character.bubble", YES},
    {kRedditFilterClassicViewer, @"Classic media viewer", @"Swipe up opens the comments", @"photo", NO},
    {kRedditFilterRedgifsSound, @"Redgifs sound (beta)", @"Play Redgifs posts with sound", @"speaker.wave.2", NO},
    // The rows from here on are shown in the Side menu section.
    {kRedditFilterHideDrawerGames, @"Games on Reddit", nil, @"gamecontroller", YES},
    {kRedditFilterHideDrawerResources, @"Resources", nil, @"square.grid.2x2", YES},
    {kRedditFilterHideDrawerRedditPro, @"Reddit Pro", nil, @"chart.bar", YES},
};
static const NSInteger kToggleRowCount = sizeof(kToggleRows) / sizeof(kToggleRows[0]);
static const NSInteger kFilterRowCount = 6;
static const NSInteger kAppToggleCount = 3;
static const NSInteger kMenuRowCount = kToggleRowCount - kFilterRowCount - kAppToggleCount;

#pragma mark - Cell helpers

static void RFApplyTheme(UIView *view, SEL setter, SEL themeGetter) {
  if ([view respondsToSelector:@selector(associatePropertySetter:withThemePropertyGetter:)])
    [view associatePropertySetter:setter withThemePropertyGetter:themeGetter];
}

static UIImage *RFBoxedImage(UIImage *image, CGFloat inset);

// A row with a switch, in plain UIKit. Switches on this screen don't receive
// taps (neither Reddit's nor UIKit's own; dragging works), so the switch only
// displays the state and a tap anywhere on the row flips it. The tap
// recognizer is added in -tableView:cellForRowAtIndexPath:.
static UITableViewCell *RFToggleCell(UITableView *tableView) {
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kToggleCellID];
  if (cell) return cell;
  cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kToggleCellID];
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  cell.accessoryView = [UISwitch new];
  cell.accessoryView.userInteractionEnabled = NO;
  cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
  cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0];
  cell.detailTextLabel.numberOfLines = 0;
  cell.textLabel.textColor = UIColor.labelColor;
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  cell.imageView.tintColor = UIColor.labelColor;
  RFApplyTheme(cell.textLabel, @selector(setTextColor:), @selector(bodyTextColor));
  RFApplyTheme(cell.detailTextLabel, @selector(setTextColor:), @selector(metaTextColor));
  RFApplyTheme(cell.imageView, @selector(setTintColor:), @selector(bodyTextColor));
  RFApplyTheme(cell, @selector(setBackgroundColor:), @selector(bodyColor));
  return cell;
}

// Section header/footer: a themed label inset like Reddit's own settings.
static UIView *RFSectionView(UITableView *tableView, NSString *text, CGFloat height) {
  if (!text) return nil;

  // Reddit's spacing class is a Swift class, so it needs CoreClass to be found.
  Class guidanceClass = CoreClass(@"LayoutGuidance");
  LayoutGuidance *guidance =
      [guidanceClass respondsToSelector:@selector(currentGuidance)] ? [guidanceClass currentGuidance] : nil;
  CGFloat padding = guidance.gridPadding > 0 ? guidance.gridPadding : 16.0;
  CGFloat width = tableView.bounds.size.width;

  Class labelClass = %c(BaseLabel);
  UILabel *label = [labelClass respondsToSelector:@selector(labelWithSubheaderFont)]
                       ? [labelClass labelWithSubheaderFont]
                       : [UILabel new];
  label.frame = CGRectMake(padding, 0, MAX(width - padding * 2, 0), height);
  label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  label.numberOfLines = 0;
  label.text = text;
  RFApplyTheme(label, @selector(setTextColor:), @selector(metaTextColor));

  Class containerClass = %c(BaseTableReusableView);
  UIView *container = [[(containerClass ?: UIView.class) alloc] initWithFrame:CGRectMake(0, 0, width, height)];
  UIView *content = [container respondsToSelector:@selector(contentView)]
                        ? ((BaseTableReusableView *)container).contentView
                        : container;
  [content addSubview:label];
  RFApplyTheme(container, @selector(setBackgroundColor:), @selector(canvasColor));
  return container;
}

#pragma mark - Sections

typedef NS_ENUM(NSInteger, RFSection) {
  RFSectionFilters,
  RFSectionApp,
  RFSectionMenu,
  RFSectionDebug,
  RFSectionAbout
};

// Filters, App, Side menu, [Schema Paths (debug builds only)], About
static const NSInteger kSectionCount = REDDITFILTER_DEBUG ? 5 : 4;

static RFSection RFSectionAt(NSInteger section) {
  if (section == 0) return RFSectionFilters;
  if (section == 1) return RFSectionApp;
  if (section == 2) return RFSectionMenu;
  if (REDDITFILTER_DEBUG && section == 3) return RFSectionDebug;
  return RFSectionAbout;
}

// Index into kToggleRows of the first toggle shown in a section.
static NSInteger RFFirstToggle(RFSection section) {
  if (section == RFSectionApp) return kFilterRowCount;
  if (section == RFSectionMenu) return kFilterRowCount + kAppToggleCount;
  return 0;
}

#pragma mark - Clear cache row

static UITableViewCell *RFCacheCell(UITableView *tableView, NSString *sizeText) {
  static NSString *const kCacheCellID = @"RFCacheCell";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCacheCellID];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kCacheCellID];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.tintColor = UIColor.labelColor;
    cell.imageView.image = [UIImage systemImageNamed:@"trash"];
    RFApplyTheme(cell.textLabel, @selector(setTextColor:), @selector(bodyTextColor));
    RFApplyTheme(cell.detailTextLabel, @selector(setTextColor:), @selector(metaTextColor));
    RFApplyTheme(cell.imageView, @selector(setTintColor:), @selector(bodyTextColor));
    RFApplyTheme(cell, @selector(setBackgroundColor:), @selector(bodyColor));
  }
  cell.textLabel.text = @"Clear cache";
  cell.detailTextLabel.text = sizeText;
  return cell;
}

#pragma mark - About section

typedef struct {
  __unsafe_unretained NSString *title;
  __unsafe_unretained NSString *subtitle; // nil = show the version
  __unsafe_unretained NSString *link;     // opened when the row is tapped
  __unsafe_unretained NSString *symbol;   // SF Symbol name, or nil to show the logo
} RFAboutRow;

static const RFAboutRow kAboutRows[] = {
    {@"RedditFilter", nil, @"https://github.com/NicholasBly/RedditFilter/releases",
     @"line.3.horizontal.decrease.circle"},
    {@"Nicholas Bly", @"Developer", @"https://github.com/NicholasBly/RedditFilter", nil},
    {@"level3tjg", @"Original creator",
     @"https://github.com/level3tjg/RedditFilter", @"person.crop.circle"},
};
static const NSInteger kAboutRowCount = sizeof(kAboutRows) / sizeof(kAboutRows[0]);
static const CGFloat kAboutIconSize = 36.0;

// Draws an image centered in a fixed-size square so every row's text lines up.
static UIImage *RFBoxedImage(UIImage *image, CGFloat inset) {
  if (!image) return nil;
  CGSize box = CGSizeMake(kAboutIconSize, kAboutIconSize);
  CGFloat side = kAboutIconSize - inset * 2;
  CGFloat scale = MIN(side / image.size.width, side / image.size.height);
  CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:box];
  UIImage *boxed = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    [image drawInRect:CGRectMake((box.width - size.width) / 2, (box.height - size.height) / 2, size.width,
                                 size.height)];
  }];
  return [boxed imageWithRenderingMode:image.renderingMode];
}

static UIImage *RFLogo(void) {
  static UIImage *logo;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSData *data = [NSData dataWithBytesNoCopy:(void *)kRFLogoPNG length:sizeof(kRFLogoPNG) freeWhenDone:NO];
    logo = RFBoxedImage([UIImage imageWithData:data], 0);
  });
  return logo;
}

static NSString *RFVersionText(void) {
  return [@"Version " @RF_VERSION stringByAppendingString:REDDITFILTER_DEBUG ? @" (debug build)" : @""];
}

static UITableViewCell *RFAboutCell(UITableView *tableView, NSInteger index) {
  static NSString *const kAboutCellID = @"RFAboutCell";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kAboutCellID];
  if (!cell) {
    // A plain UIKit cell, colored with Reddit's theme when it's available.
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kAboutCellID];
    cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0];
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.tintColor = UIColor.secondaryLabelColor;
    RFApplyTheme(cell.textLabel, @selector(setTextColor:), @selector(bodyTextColor));
    RFApplyTheme(cell.detailTextLabel, @selector(setTextColor:), @selector(metaTextColor));
    RFApplyTheme(cell.imageView, @selector(setTintColor:), @selector(metaTextColor));
    RFApplyTheme(cell, @selector(setBackgroundColor:), @selector(bodyColor));
  }
  if (index < 0 || index >= kAboutRowCount) return cell;
  const RFAboutRow *row = &kAboutRows[index];
  cell.textLabel.text = row->title;
  cell.detailTextLabel.text = row->subtitle ?: RFVersionText();
  cell.imageView.image = row->symbol ? RFBoxedImage([UIImage systemImageNamed:row->symbol], 7.0) : RFLogo();
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  return cell;
}

#if REDDITFILTER_DEBUG
// Declarations for the debug-only helpers so the call sites below are typed.
// (The implementations are added to the class at runtime by Logos below.)
@interface FeedFilterSettingsViewController (RFSchemaDebug)
- (UITableViewCell *)debugCellForRow:(NSInteger)row inTableView:(UITableView *)tableView;
- (void)rfCopyDiscoveredPath:(UIButton *)sender;
- (void)rfCopyFailedJSON:(UIButton *)sender;
- (void)rfResetCounters:(UIButton *)sender;
@end
#endif

@interface FeedFilterSettingsViewController (RFCache)
- (void)rfRefreshCacheSize;
- (void)rfToggleChanged:(UISwitch *)sender;
@end

%subclass FeedFilterSettingsViewController : BaseTableViewController

- (void)viewDidLoad {
  %orig;
  self.title = @"RedditFilter";
#if REDDITFILTER_DEBUG
  // Debug rows carry multi-line detail text, so let them self-size.
  self.tableView.estimatedRowHeight = 60.0;
  self.tableView.rowHeight = UITableViewAutomaticDimension;
#endif
}

- (void)viewWillAppear:(BOOL)animated {
  %orig;
  [self rfRefreshCacheSize];
#if REDDITFILTER_DEBUG
  // Stats accrue while the app runs; refresh them each time the screen opens.
  [self.tableView reloadData];
#endif
}

%new
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return kSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  switch (RFSectionAt(section)) {
    case RFSectionFilters:
      return kFilterRowCount;
    case RFSectionApp:
      return kAppToggleCount + 1; // the toggles, then "Clear cache"
    case RFSectionMenu:
      return kMenuRowCount;
    case RFSectionDebug:
#if REDDITFILTER_DEBUG
      // One row per tracked schema path, plus a trailing "reset" row.
      return [[RFSchemaDebug shared] snapshot].count + 1;
#endif
      return 0;
    case RFSectionAbout:
      return kAboutRowCount;
  }
  return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  RFSection section = RFSectionAt(indexPath.section);
  if (section == RFSectionAbout) return RFAboutCell(tableView, indexPath.row);
#if REDDITFILTER_DEBUG
  if (section == RFSectionDebug) return [self debugCellForRow:indexPath.row inTableView:tableView];
#endif
  if (section == RFSectionApp && indexPath.row >= kAppToggleCount)
    return RFCacheCell(tableView, objc_getAssociatedObject(self, @selector(rfRefreshCacheSize)));
  UITableViewCell *cell = RFToggleCell(tableView);
  NSInteger index = RFFirstToggle(section) + indexPath.row;
  if (index >= kToggleRowCount) return cell;
  const RFToggleRow *row = &kToggleRows[index];

  cell.textLabel.text = row->title;
  cell.detailTextLabel.text = row->subtitle;
  cell.imageView.image = RFBoxedImage([UIImage systemImageNamed:row->symbol], 6.0);

  UISwitch *toggle = (UISwitch *)cell.accessoryView;
  BOOL saved = [NSUserDefaults.standardUserDefaults boolForKey:row->key];
  toggle.on = row->switchOnMeansShow ? !saved : saved;
  toggle.tag = index;
  if (!cell.gestureRecognizers.count)
    [cell addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rfRowTapped:)]];
  return cell;
}

%new
- (void)rfRowTapped:(UITapGestureRecognizer *)recognizer {
  UISwitch *toggle = (UISwitch *)((UITableViewCell *)recognizer.view).accessoryView;
  [toggle setOn:!toggle.on animated:YES];
  [self rfToggleChanged:toggle];
}

%new
- (void)rfToggleChanged:(UISwitch *)sender {
  if (sender.tag < 0 || sender.tag >= kToggleRowCount) return;
  const RFToggleRow *row = &kToggleRows[sender.tag];
  BOOL filterOn = row->switchOnMeansShow ? !sender.on : sender.on;
  [NSUserDefaults.standardUserDefaults setBool:filterOn forKey:row->key];
  RFReloadPreferences();
}

%new
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (RFSectionAt(indexPath.section) == RFSectionApp && indexPath.row >= kAppToggleCount) {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Clear cache?"
                                            message:@"Deletes downloaded images, videos and other temporary "
                                                    @"files. You stay logged in and your settings are kept."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
                                              dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                                                RFClearCache();
                                                dispatch_async(dispatch_get_main_queue(), ^{ [self rfRefreshCacheSize]; });
                                              });
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
    return;
  }
  if (RFSectionAt(indexPath.section) != RFSectionAbout || indexPath.row >= kAboutRowCount) return;
  NSURL *url = [NSURL URLWithString:kAboutRows[indexPath.row].link];
  if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

// Measures the cache in the background, then shows the result in its row.
%new
- (void)rfRefreshCacheSize {
  __weak FeedFilterSettingsViewController *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSString *text = [NSByteCountFormatter stringFromByteCount:(long long)RFCacheSize()
                                                    countStyle:NSByteCountFormatterCountStyleFile];
    dispatch_async(dispatch_get_main_queue(), ^{
      FeedFilterSettingsViewController *controller = weakSelf;
      if (!controller) return;
      objc_setAssociatedObject(controller, @selector(rfRefreshCacheSize), text, OBJC_ASSOCIATION_COPY_NONATOMIC);
      [controller.tableView reloadData];
    });
  });
}

%new
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  NSString *text = nil;
  switch (RFSectionAt(section)) {
    case RFSectionFilters: text = @"FILTERS"; break;
    case RFSectionApp: text = @"APP"; break;
    case RFSectionMenu: text = @"SIDE MENU"; break;
    case RFSectionDebug: text = @"SCHEMA PATHS · DEBUG"; break;
    case RFSectionAbout: text = @"ABOUT"; break;
  }
  return RFSectionView(tableView, text, 40.0);
}

%new
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return 40.0;
}

%new
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
  NSString *text = nil;
  switch (RFSectionAt(section)) {
    case RFSectionFilters:
      text = @"Filter specific types of posts from your feed";
      break;
    case RFSectionApp:
      text = @"Restart the app to apply the media viewer";
      break;
    case RFSectionMenu:
      text = @"Sections of the menu on the home screen";
      break;
    case RFSectionDebug:
      text = @"✓ resolved · ✗ broke (structural fallback is now filtering). "
             @"Tap Copy on a ✗ row to grab the auto-discovered replacement path.";
      break;
    case RFSectionAbout:
      break; // no footer, just some space at the bottom
  }
  return RFSectionView(tableView, text, [self tableView:tableView heightForFooterInSection:section]);
}

%new
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  return RFSectionAt(section) == RFSectionDebug ? 76.0 : 40.0;
}

// ---------------------------------------------------------------------------
// Schema-path debug section.
//
// All of the method *declarations* below are compiled unconditionally so that
// Logos always registers them on the subclass; only their bodies are gated on
// REDDITFILTER_DEBUG. In a release build the bodies collapse to no-ops, the
// section is never shown (numberOfSections returns 1), and these methods are
// never invoked.
// ---------------------------------------------------------------------------
%new
- (UITableViewCell *)debugCellForRow:(NSInteger)row inTableView:(UITableView *)tableView {
#if REDDITFILTER_DEBUG
  static NSString *const kRFDebugCellID = @"RFSchemaDebugCell";
  
  // Deliberately a plain UIKit cell, not a Reddit class: the whole point of
  // this screen is to keep working when Reddit's own classes/schema change.
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kRFDebugCellID];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:kRFDebugCellID];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11.0
                                                            weight:UIFontWeightRegular];
    cell.textLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
  }
  cell.accessoryView = nil;
  cell.selectionStyle = UITableViewCellSelectionStyleNone;

  NSArray<NSDictionary *> *snapshot = [[RFSchemaDebug shared] snapshot];
  
  // Trailing "reset" row.
  if (row >= (NSInteger)snapshot.count) {
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.textLabel.text = @"Reset counters";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.text = @"Clear all stats and re-arm path discovery";
    UIButton *resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetButton setTitle:@"Reset" forState:UIControlStateNormal];
    resetButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    [resetButton addTarget:self
                    action:@selector(rfResetCounters:)
          forControlEvents:UIControlEventTouchUpInside];
    [resetButton sizeToFit];
    cell.accessoryView = resetButton;
    return cell;
  }

  NSDictionary *record = snapshot[row];
  NSString *op = record[kRFDebugOp];
  NSString *expected = record[kRFDebugExpected];
  NSString *discovered = record[kRFDebugDiscovered];
  NSInteger hits = [record[kRFDebugHits] integerValue];
  NSInteger misses = [record[kRFDebugMisses] integerValue];
  BOOL seen = [record[kRFDebugSeen] boolValue];
  BOOL lastResolved = [record[kRFDebugLastResolved] boolValue];

  cell.textLabel.textColor = [UIColor labelColor];
  cell.textLabel.text = op;

  NSString *detail;
  UIColor *detailColor;
  if (!seen) {
    detail = [NSString stringWithFormat:@"untested\nexpected: %@", expected];
    detailColor = [UIColor secondaryLabelColor];
  } else if (lastResolved) {
    detail = [NSString stringWithFormat:@"\u2713 OK \u00b7 %ld hit%@",
                                        (long)hits, hits == 1 ? @"" : @"s"];
    if (misses > 0)
      detail = [detail stringByAppendingFormat:@"  (recovered after %ld miss%@)",
                                               (long)misses, misses == 1 ? @"" : @"es"];
    detailColor = [UIColor systemGreenColor];
  } else {
    detail = [NSString stringWithFormat:@"\u2717 MISS \u00b7 %ld miss%@ \u00b7 fallback active",
                                        (long)misses, misses == 1 ? @"" : @"es"];
    if (discovered.length) {
      detail = [detail stringByAppendingFormat:@"\n\u2192 %@", discovered];
      UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
      [copyButton setTitle:@"Copy" forState:UIControlStateNormal];
      copyButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
      copyButton.tag = row;
      [copyButton addTarget:self
                     action:@selector(rfCopyDiscoveredPath:)
           forControlEvents:UIControlEventTouchUpInside];
      [copyButton sizeToFit];
      cell.accessoryView = copyButton;
    } else {
      detail = [detail stringByAppendingFormat:@"\ncould not auto-locate a new path\nexpected: %@",
                                               expected];
                                               
      // Show the "Copy JSON" button if we captured a payload
      NSString *failedJSON = record[kRFDebugFailedJSON];
      if (failedJSON.length > 0) {
          detail = [detail stringByAppendingString:@"\n\u2192 raw payload captured"];
          UIButton *copyJsonButton = [UIButton buttonWithType:UIButtonTypeSystem];
          [copyJsonButton setTitle:@"Copy JSON" forState:UIControlStateNormal];
          copyJsonButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
          copyJsonButton.tag = row;
          [copyJsonButton addTarget:self
                             action:@selector(rfCopyFailedJSON:)
                   forControlEvents:UIControlEventTouchUpInside];
          [copyJsonButton sizeToFit];
          cell.accessoryView = copyJsonButton;
      }
    }
    detailColor = [UIColor systemRedColor];
  }
  cell.detailTextLabel.text = detail;
  cell.detailTextLabel.textColor = detailColor;
  return cell;
#else
  return nil;
#endif
}
%new
- (void)rfCopyDiscoveredPath:(UIButton *)sender {
#if REDDITFILTER_DEBUG
  NSArray<NSDictionary *> *snapshot = [[RFSchemaDebug shared] snapshot];
  if (sender.tag < 0 || sender.tag >= (NSInteger)snapshot.count) return;
  NSString *discovered = snapshot[sender.tag][kRFDebugDiscovered];
  if (!discovered.length) return;
  UIPasteboard.generalPasteboard.string = discovered;
  [sender setTitle:@"Copied" forState:UIControlStateNormal];
  [sender sizeToFit];
  __weak UIButton *weakSender = sender;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [weakSender setTitle:@"Copy" forState:UIControlStateNormal];
                   [weakSender sizeToFit];
                 });
#endif
}
%new
- (void)rfCopyFailedJSON:(UIButton *)sender {
#if REDDITFILTER_DEBUG
  NSArray<NSDictionary *> *snapshot = [[RFSchemaDebug shared] snapshot];
  if (sender.tag < 0 || sender.tag >= (NSInteger)snapshot.count) return;
  
  NSString *failedJSON = snapshot[sender.tag][kRFDebugFailedJSON];
  if (!failedJSON.length) return;
  
  UIPasteboard.generalPasteboard.string = failedJSON;
  [sender setTitle:@"Copied" forState:UIControlStateNormal];
  [sender sizeToFit];
  
  __weak UIButton *weakSender = sender;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [weakSender setTitle:@"Copy JSON" forState:UIControlStateNormal];
                   [weakSender sizeToFit];
                 });
#endif
}
%new
- (void)rfResetCounters:(UIButton *)sender {
#if REDDITFILTER_DEBUG
  [[RFSchemaDebug shared] reset];
  [self.tableView reloadData];
#endif
}
%end
