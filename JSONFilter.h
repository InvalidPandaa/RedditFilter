// JSONFilter.h
//
// Pure-Foundation response filtering used by the NSURLSession hook in
// Tweak.xm. Nothing in here touches UIKit or Reddit classes, which keeps the
// logic small, easy to read and testable on its own.

#import <Foundation/Foundation.h>

typedef struct {
  BOOL promoted;
  BOOL recommended;
  BOOL nsfw;
  BOOL awards;
  BOOL scores;
  BOOL automod;
  BOOL classicViewer; // the media viewer as it was before the vertical post feed
  BOOL redgifsSound;  // play Redgifs posts from Redgifs, which has the sound
} RFPrefs;

// Given the Redgifs IDs found in a response, returns those that can be played
// from Redgifs with sound. May block; called on the thread that filters.
typedef NSSet<NSString *> * (^RFRedgifsResolver)(NSSet<NSString *> *ids);

#ifdef __cplusplus
extern "C" {
#endif

// YES if at least one filter is switched on.
BOOL RFPrefsAnyEnabled(RFPrefs prefs);

// Best-effort GraphQL operation name for a request: the Apollo
// X-APOLLO-OPERATION-NAME header, then "operationName" in the JSON body, then
// the ?operationName= query item. Returns @"Unknown" when none is found.
NSString *RFOperationName(NSURLRequest *request);

// Filters a GraphQL response. Returns the new response bytes, or nil when the
// response was left untouched (not JSON, ignored operation, nothing to change),
// in which case the caller should pass the original data through.
NSData *RFFilteredResponseData(NSData *data, NSString *operationName, RFPrefs prefs);

// Who decides which Redgifs posts get the Redgifs stream. Without a resolver
// nothing is changed. Set once at startup.
void RFSetRedgifsResolver(RFRedgifsResolver resolver);

// The ID in a Redgifs link ("https://www.redgifs.com/watch/SomeId" -> "someid"), or nil.
NSString *RFRedgifsID(NSString *link);

// The stream Redgifs offers for an ID: video and sound in one HLS playlist.
NSString *RFRedgifsStreamURL(NSString *redgifsID);

#ifdef __cplusplus
}
#endif
