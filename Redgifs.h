// Redgifs.h
//
// Finds out which Redgifs videos can be played straight from Redgifs with
// sound. Used by the response filter for the "Redgifs sound" setting.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Of the given Redgifs IDs, those whose stream is reachable and has a sound
// track. Asks Redgifs for the ones not seen before and waits a short time for
// the answers, so call it from a background thread. Slow answers are still
// remembered for the next call.
NSSet<NSString *> *RFPlayableRedgifs(NSSet<NSString *> *ids);

// YES for the address of a stream put in place by the "Redgifs sound" setting.
BOOL RFIsRedgifsStream(id url);

#ifdef __cplusplus
}
#endif
