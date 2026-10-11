// Runs JSONFilter.m on macOS against the JSON files in Tests/Fixtures.
// Usage: Tests/run.sh   (fixture name = GraphQL operation name)

#import <Foundation/Foundation.h>
#import "JSONFilter.h"

static int failures = 0;
static NSString *fixturesDir;

#define CHECK(cond, ...)                                                        \
  do {                                                                          \
    if (!(cond)) {                                                              \
      failures++;                                                               \
      NSLog(@"FAIL %s:%d  %@", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__]); \
    }                                                                           \
  } while (0)

static NSData *Fixture(NSString *op) {
  NSData *data = [NSData dataWithContentsOfFile:[fixturesDir stringByAppendingFormat:@"/%@.json", op]];
  if (!data) {
    NSLog(@"missing fixture %@", op);
    exit(2);
  }
  return data;
}

// Filtered JSON, or the untouched input when the filter reports "no change".
static NSDictionary *Run(NSString *op, RFPrefs prefs, BOOL *changed) {
  NSData *input = Fixture(op);
  NSData *output = RFFilteredResponseData(input, op, prefs);
  if (changed) *changed = output != nil;
  return [NSJSONSerialization JSONObjectWithData:(output ?: input) options:0 error:NULL];
}

static NSDictionary *FeedNode(NSDictionary *json, NSString *path, NSString *groupId) {
  for (NSDictionary *edge in [json valueForKeyPath:path])
    if ([edge[@"node"][@"groupId"] isEqual:groupId]) return edge[@"node"];
  return nil;
}

static void TestHomeFeed(void) {
  NSString *path = @"data.homeV3.elements.edges";
  BOOL changed;

  NSDictionary *json = Run(@"HomeFeedSdui", (RFPrefs){.promoted = YES}, &changed);
  CHECK(changed, @"promoted filter should change the home feed");
  CHECK([FeedNode(json, path, @"ad")[@"cells"] count] == 0, @"ad cells should be emptied");
  CHECK([FeedNode(json, path, @"organic")[@"cells"] count] == 2, @"organic post must stay");
  CHECK([FeedNode(json, path, @"recommended")[@"cells"] count] == 1, @"recommendation stays when only promoted is on");

  json = Run(@"HomeFeedSdui", (RFPrefs){.recommended = YES}, &changed);
  CHECK([FeedNode(json, path, @"recommended")[@"cells"] count] == 0, @"recommendation should be emptied");
  CHECK([FeedNode(json, path, @"popularFiller")[@"cells"] count] == 1, @"popular filler must stay");
  CHECK([FeedNode(json, path, @"nullContext")[@"cells"] count] == 1, @"null recommendationContext must not match");
  CHECK([FeedNode(json, path, @"ad")[@"cells"] count] == 1, @"ad stays when promoted is off");

  json = Run(@"HomeFeedSdui", (RFPrefs){.awards = YES, .scores = YES}, &changed);
  NSDictionary *action = FeedNode(json, path, @"organic")[@"cells"][1];
  CHECK([action[@"isScoreHidden"] boolValue], @"score should be hidden");
  CHECK([action[@"isAwardHidden"] boolValue], @"award should be hidden");
  CHECK(![action[@"goldenUpvoteInfo"][@"isGildable"] boolValue], @"gilding should be off");

  Run(@"HomeFeedSdui", (RFPrefs){0}, &changed);
  CHECK(!changed, @"no prefs: response must pass through untouched");
}

static void TestPopularFeed(void) {
  NSString *path = @"data.popularV3.elements.edges";
  NSDictionary *json = Run(@"PopularFeedSdui", (RFPrefs){.promoted = YES, .recommended = YES}, NULL);
  CHECK([FeedNode(json, path, @"p1")[@"cells"] count] == 1, @"recommended filter must not wipe Popular");
  CHECK([FeedNode(json, path, @"ad")[@"cells"] count] == 0, @"ads are still removed from Popular");
}

static void TestComments(void) {
  RFPrefs all = {.promoted = YES, .nsfw = YES, .awards = YES, .scores = YES, .automod = YES};
  NSDictionary *post = Run(@"PostInfoById", all, NULL)[@"data"][@"postInfoById"];
  NSArray *trees = post[@"commentForest"][@"trees"];
  CHECK([trees[0][@"node"][@"isInitiallyCollapsed"] boolValue], @"AutoModerator comment should collapse");
  CHECK(![trees[1][@"node"][@"isInitiallyCollapsed"] boolValue], @"other comments stay expanded");
  CHECK([trees[0][@"node"][@"awardings"] count] == 0, @"comment awards should be removed");
  CHECK([trees[2][@"node"][@"isHidden"] boolValue], @"ad in comment tree should be hidden");
  CHECK([post[@"isHidden"] boolValue], @"NSFW post should be hidden");
  CHECK([post[@"isScoreHidden"] boolValue], @"post score should be hidden");

  BOOL changed;
  NSDictionary *ads = Run(@"PdpCommentsAds", (RFPrefs){.promoted = YES}, &changed);
  CHECK(changed && [ads[@"data"][@"postInfoById"][@"pdpCommentsAds"] count] == 0, @"comment ads should be cleared");
}

static void TestRobustness(void) {
  RFPrefs all = {YES, YES, YES, YES, YES, YES, YES};
  for (NSString *text in @[ @"", @"not json", @"[]", @"{\"data\":null}", @"{\"errors\":[]}", @"{\"data\":{\"x\":null,\"y\":[null,1,\"s\"]}}" ]) {
    NSData *out = RFFilteredResponseData([text dataUsingEncoding:NSUTF8StringEncoding], @"Unknown", all);
    CHECK(out == nil, @"'%@' should pass through untouched", text);
  }
  CHECK(RFFilteredResponseData(Fixture(@"HomeFeedSdui"), @"GetAccount", all) == nil, @"ignored operation is skipped");
  // Renamed schema (homeV3 -> homeV4): the generic fallback must still catch ads.
  NSString *renamed = [[[NSString alloc] initWithData:Fixture(@"HomeFeedSdui") encoding:NSUTF8StringEncoding]
      stringByReplacingOccurrencesOfString:@"homeV3" withString:@"homeV4"];
  NSData *out = RFFilteredResponseData([renamed dataUsingEncoding:NSUTF8StringEncoding], @"HomeFeedSdui", all);
  NSDictionary *json = out ? [NSJSONSerialization JSONObjectWithData:out options:0 error:NULL] : nil;
  CHECK([FeedNode(json, @"data.homeV4.elements.edges", @"ad")[@"cells"] count] == 0, @"fallback should filter a renamed feed");
}

static void TestExperiments(void) {
  BOOL changed;
  NSDictionary *json = Run(@"GetAllExperimentVariants", (RFPrefs){.classicViewer = YES}, &changed);
  NSArray *names = [json valueForKeyPath:@"data.experimentVariants.experimentName"];
  CHECK(changed, @"classic viewer should change the experiment list");
  CHECK(names.count == 3, @"the three viewer redesign experiments should be removed, got %@", names);
  CHECK([names containsObject:@"ios_screenshot_sharing"], @"unrelated experiments must stay");
  CHECK([names containsObject:@"ios_fbp_flex_overlays"], @"other viewer experiments must stay");

  Run(@"GetAllExperimentVariants", (RFPrefs){.promoted = YES}, &changed);
  CHECK(!changed, @"experiments must stay untouched when classic viewer is off");
}

static void TestRedgifs(void) {
  CHECK([RFRedgifsID(@"https://www.redgifs.com/watch/SomeId") isEqualToString:@"someid"], @"watch link");
  CHECK([RFRedgifsID(@"https://v3.redgifs.com/ifr/someid-tag-other") isEqualToString:@"someid"], @"embed link with tags");
  CHECK(!RFRedgifsID(@"https://i.redgifs.com/i/someid.jpg"), @"images are not videos");
  CHECK(!RFRedgifsID(@"https://notredgifs.com/watch/someid"), @"other hosts");
  CHECK(!RFRedgifsID(@"https://www.youtube.com/watch?v=abc"), @"other sites");

  __block NSSet *asked = nil;
  RFSetRedgifsResolver(^(NSSet<NSString *> *ids) {
    asked = ids;
    return [NSSet setWithObject:@"playablewithsound"];
  });
  RFPrefs on = {.redgifsSound = YES};
  NSString *stream = @"https://api.redgifs.com/v2/gifs/playablewithsound/hd.m3u8";
  NSString *edges = @"data.subredditV3.elements.edges";

  BOOL changed;
  NSDictionary *json = Run(@"SubredditFeedSdui", on, &changed);
  CHECK(changed, @"a playable Redgifs post should change the feed");
  CHECK([asked isEqualToSet:([NSSet setWithObjects:@"playablewithsound", @"silentone", nil])], @"asked for %@", asked);
  NSDictionary *video = FeedNode(json, edges, @"redgifs")[@"cells"][2];
  CHECK([video[@"media"][@"path"] isEqual:stream], @"feed video should play from Redgifs, got %@", video[@"media"]);
  CHECK([video[@"isGif"] isEqual:@NO], @"feed video must no longer be a silent GIF");
  CHECK(video[@"packagedMedia"] == NSNull.null, @"Reddit's silent MP4s must go");
  CHECK([video[@"preview"][@"path"] hasPrefix:@"https://external-preview"], @"the preview image stays");
  video = FeedNode(json, edges, @"silent")[@"cells"][1];
  CHECK([video[@"media"][@"path"] hasPrefix:@"https://v.redd.it/bbb"], @"an unplayable Redgifs post keeps Reddit's copy");
  CHECK([video[@"isGif"] isEqual:@YES], @"an unplayable Redgifs post stays a GIF");
  video = FeedNode(json, edges, @"reddit-video")[@"cells"][1];
  CHECK([video[@"media"][@"path"] hasPrefix:@"https://v.redd.it/ccc"], @"other videos stay untouched");

  json = Run(@"SearchDynamic", on, &changed);
  NSArray *posts = [json valueForKeyPath:@"data.search.dynamic.components.main.edges"][0][@"node"][@"children"];
  NSDictionary *media = posts[0][@"post"][@"media"];
  CHECK(changed, @"a playable Redgifs post should change the search results");
  CHECK([media[@"streaming"][@"hlsUrl"] isEqual:stream], @"post should play from Redgifs, got %@", media[@"streaming"]);
  CHECK([media[@"streaming"][@"isGif"] isEqual:@NO], @"post must no longer be a silent GIF");
  CHECK(media[@"packagedMedia"] == NSNull.null, @"Reddit's silent MP4s must go");
  CHECK([media[@"video"][@"url"] hasPrefix:@"https://www.redgifs.com/watch/"], @"the link itself stays");
  CHECK(posts[1][@"post"][@"media"][@"streaming"] == NSNull.null, @"other embeds stay untouched");

  asked = nil;
  Run(@"SubredditFeedSdui", (RFPrefs){.promoted = YES}, &changed);
  CHECK(!changed && !asked, @"nothing happens while the setting is off");
  Run(@"HomeFeedSdui", on, NULL);
  CHECK(!asked, @"Redgifs is not asked about feeds without Redgifs posts");

  RFSetRedgifsResolver(nil);
  Run(@"SubredditFeedSdui", on, &changed);
  CHECK(!changed, @"nothing happens without a resolver");
}

static void TestOperationName(void) {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql-fed.reddit.com/?operationName=FromQuery"]];
  CHECK([RFOperationName(request) isEqualToString:@"FromQuery"], @"query item");
  request.HTTPBody = [@"{\"operationName\" : \"FromBody\"}" dataUsingEncoding:NSUTF8StringEncoding];
  CHECK([RFOperationName(request) isEqualToString:@"FromBody"], @"body beats query");
  [request setValue:@"FromHeader" forHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"];
  CHECK([RFOperationName(request) isEqualToString:@"FromHeader"], @"header beats body");
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    fixturesDir = argc > 1 ? @(argv[1]) : @"Tests/Fixtures";
    TestHomeFeed();
    TestPopularFeed();
    TestComments();
    TestRobustness();
    TestExperiments();
    TestRedgifs();
    TestOperationName();
    printf(failures ? "%d check(s) FAILED\n" : "all checks passed\n", failures);
    return failures ? 1 : 0;
  }
}
