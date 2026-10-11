// DrawerSections.x
//
// Hides sections of the community drawer (the side menu behind the ☰ button
// on the home screen): "Games on Reddit", "Resources" and "Reddit Pro".
//
// The drawer is a table view fed by a diffable data source. Its sections are
// values of the Swift enum CommunityDrawer.CommunityDrawerViewSection, which
// describe themselves as e.g.
//   CommunityDrawer.CommunityDrawerViewSection.gamesOnReddit(isCollapsed: false)
// Every list of sections passes through the private Objective-C class hooked
// below before it is shown, so unwanted sections are deleted from it there.

#import <UIKit/UIKit.h>
#import "Preferences.h"

@interface __UIDiffableDataSource : NSObject
@end

@interface NSObject (RFDiffableSnapshot)
- (NSArray *)sectionIdentifiers;
- (void)deleteSectionsWithIdentifiers:(NSArray *)identifiers;
@end

static NSString *const kSectionPrefix = @"CommunityDrawer.CommunityDrawerViewSection.";

static void RFRemoveHiddenSections(id snapshot) {
  if (![snapshot respondsToSelector:@selector(sectionIdentifiers)] ||
      ![snapshot respondsToSelector:@selector(deleteSectionsWithIdentifiers:)])
    return;
  NSArray *sections = [snapshot sectionIdentifiers];
  // This runs for every list in the app; leave quickly unless it is the drawer.
  if (![[sections.firstObject description] hasPrefix:kSectionPrefix]) return;

  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSDictionary<NSString *, NSString *> *settingForSection = @{
    @"gamesOnReddit" : kRedditFilterHideDrawerGames,
    @"resources" : kRedditFilterHideDrawerResources,
    @"redditPro" : kRedditFilterHideDrawerRedditPro,
  };
  NSMutableArray *hidden = [NSMutableArray array];
  for (id section in sections) {
    NSString *name = [section description];
    if (![name hasPrefix:kSectionPrefix]) continue;
    name = [name substringFromIndex:kSectionPrefix.length];
    name = [name componentsSeparatedByString:@"("].firstObject; // drop "(isCollapsed: ...)"
    NSString *setting = settingForSection[name];
    if (setting && [defaults boolForKey:setting]) [hidden addObject:section];
  }
  if (hidden.count) [snapshot deleteSectionsWithIdentifiers:hidden];
}

%hook __UIDiffableDataSource

- (void)applyDifferencesFromSnapshot:(id)snapshot {
  RFRemoveHiddenSections(snapshot);
  %orig;
}

- (void)applyDifferencesFromSnapshot:(id)snapshot animatingDifferences:(BOOL)animated {
  RFRemoveHiddenSections(snapshot);
  %orig;
}

- (void)applyDifferencesFromSnapshot:(id)snapshot
                animatingDifferences:(BOOL)animated
                          completion:(void (^)(void))completion {
  RFRemoveHiddenSections(snapshot);
  %orig;
}

- (void)applyDifferencesFromSnapshot:(id)snapshot completion:(void (^)(void))completion {
  RFRemoveHiddenSections(snapshot);
  %orig;
}

- (void)reloadFromSnapshot:(id)snapshot {
  RFRemoveHiddenSections(snapshot);
  %orig;
}

- (void)reloadFromSnapshot:(id)snapshot completion:(void (^)(void))completion {
  RFRemoveHiddenSections(snapshot);
  %orig;
}

%end
