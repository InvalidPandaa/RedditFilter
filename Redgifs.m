// Redgifs.m
//
// See Redgifs.h. A Redgifs stream is a playlist that points into one media
// file. Some videos are not available to everyone and many have no sound; for
// those Reddit's own copy stays in place, so both are checked before a post is
// switched over: the playlist must load, and the first bytes of the media file
// (its header) must load and list a sound track.

#import "Redgifs.h"
#import "JSONFilter.h"

// How long a response from Reddit may be held back while Redgifs is asked.
static const NSTimeInterval kMaxWait = 2.0;
static const NSTimeInterval kRequestTimeout = 6.0;

static NSURLSession *RFRedgifsSession(void) {
  static NSURLSession *session;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = kRequestTimeout;
    session = [NSURLSession sessionWithConfiguration:config];
  });
  return session;
}

// The media file a playlist points to and the length of its header, from a line like
//   #EXT-X-MAP:URI="https://media.redgifs.com/SomeId.m4s",BYTERANGE="871@0"
static NSURL *RFHeaderLocation(NSString *playlist, NSInteger *length) {
  static NSRegularExpression *regex;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    regex = [[NSRegularExpression alloc] initWithPattern:@"#EXT-X-MAP:URI=\"([^\"]+)\",BYTERANGE=\"(\\d+)@0\""
                                                 options:0
                                                   error:NULL];
  });
  NSTextCheckingResult *match = playlist ? [regex firstMatchInString:playlist options:0 range:NSMakeRange(0, playlist.length)] : nil;
  if (match.numberOfRanges < 3) return nil;
  *length = [playlist substringWithRange:[match rangeAtIndex:2]].integerValue;
  return [NSURL URLWithString:[playlist substringWithRange:[match rangeAtIndex:1]]];
}

static BOOL RFSucceeded(NSURLResponse *response, NSData *data) {
  NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
  return status >= 200 && status < 300 && data.length;
}

// Calls back with @YES (playable with sound), @NO (not), or nil when Redgifs
// could not be reached, in which case the question is asked again next time.
static void RFCheckRedgifs(NSString *redgifsID, void (^done)(NSNumber *playable)) {
  NSURL *playlistURL = [NSURL URLWithString:RFRedgifsStreamURL(redgifsID)];
  [[RFRedgifsSession() dataTaskWithURL:playlistURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    if (error) return done(nil);
    NSInteger length = 0;
    NSURL *media = RFSucceeded(response, data)
        ? RFHeaderLocation([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], &length) : nil;
    if (!media || length <= 0 || length > 65536) return done(@NO);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:media];
    [request setValue:[NSString stringWithFormat:@"bytes=0-%ld", (long)length - 1] forHTTPHeaderField:@"Range"];
    [[RFRedgifsSession() dataTaskWithRequest:request completionHandler:^(NSData *header, NSURLResponse *response, NSError *error) {
      if (error) return done(nil);
      // "soun" is how an MP4 header marks a sound track.
      NSData *sound = [@"soun" dataUsingEncoding:NSASCIIStringEncoding];
      BOOL hasSound = RFSucceeded(response, header) &&
          [header rangeOfData:sound options:0 range:NSMakeRange(0, header.length)].location != NSNotFound;
      done(@(hasSound));
    }] resume];
  }] resume];
}

BOOL RFIsRedgifsStream(id url) {
  if ([url isKindOfClass:NSString.class]) url = [NSURL URLWithString:url];
  return [url isKindOfClass:NSURL.class] && [[url host] isEqualToString:@"api.redgifs.com"];
}

NSSet<NSString *> *RFPlayableRedgifs(NSSet<NSString *> *ids) {
  static NSMutableDictionary<NSString *, NSNumber *> *known; // guarded by @synchronized(known)
  static dispatch_once_t once;
  dispatch_once(&once, ^{ known = [NSMutableDictionary dictionary]; });

  dispatch_group_t group = dispatch_group_create();
  for (NSString *redgifsID in ids) {
    @synchronized(known) {
      if (known[redgifsID]) continue;
    }
    dispatch_group_enter(group);
    RFCheckRedgifs(redgifsID, ^(NSNumber *playable) {
      @synchronized(known) {
        if (playable) known[redgifsID] = playable;
      }
      dispatch_group_leave(group);
    });
  }
  dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMaxWait * NSEC_PER_SEC)));

  NSMutableSet *playable = [NSMutableSet set];
  @synchronized(known) {
    for (NSString *redgifsID in ids)
      if (known[redgifsID].boolValue) [playable addObject:redgifsID];
  }
  return playable;
}
