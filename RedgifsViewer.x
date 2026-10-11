// RedgifsViewer.x
//
// Part of the "Redgifs sound" setting. The full-screen media viewer decides on
// its own that a Redgifs post is a GIF, and plays GIFs muted and without a
// sound button. A post that got the Redgifs stream (see JSONFilter.m) is a
// video with sound, so the viewer is told so.

#import <Foundation/Foundation.h>
#import "Redgifs.h"

@interface TheatreMediaItem : NSObject
@property(nonatomic, strong) id contentUrl;
@end

%hook TheatreMediaItem

- (BOOL)isGif {
  return RFIsRedgifsStream(self.contentUrl) ? NO : %orig;
}

%end
