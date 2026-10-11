// CacheCleaner.m — see CacheCleaner.h.

#import "CacheCleaner.h"

// Left alone: the chat database is open while the app runs, and deleting an
// open database can corrupt it.
static BOOL RFIsProtected(NSString *name) { return [name isEqualToString:@"MatrixChat"]; }

static NSURL *RFCachesURL(void) {
  return [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
}

static NSArray<NSURL *> *RFCacheEntries(void) {
  NSURL *caches = RFCachesURL();
  if (!caches) return @[];
  NSMutableArray *entries = [NSMutableArray array];
  for (NSURL *entry in [NSFileManager.defaultManager contentsOfDirectoryAtURL:caches
                                                   includingPropertiesForKeys:nil
                                                                      options:0
                                                                        error:NULL])
    if (!RFIsProtected(entry.lastPathComponent)) [entries addObject:entry];
  return entries;
}

unsigned long long RFCacheSize(void) {
  unsigned long long total = 0;
  NSArray *keys = @[ NSURLIsRegularFileKey, NSURLTotalFileAllocatedSizeKey ];
  for (NSURL *entry in RFCacheEntries()) {
    NSNumber *size = nil;
    if ([entry getResourceValue:&size forKey:NSURLTotalFileAllocatedSizeKey error:NULL]) total += size.unsignedLongLongValue;
    for (NSURL *file in [NSFileManager.defaultManager enumeratorAtURL:entry
                                           includingPropertiesForKeys:keys
                                                              options:0
                                                         errorHandler:nil]) {
      NSDictionary *values = [file resourceValuesForKeys:keys error:NULL];
      if ([values[NSURLIsRegularFileKey] boolValue])
        total += [values[NSURLTotalFileAllocatedSizeKey] unsignedLongLongValue];
    }
  }
  return total;
}

void RFClearCache(void) {
  // The shared URL cache keeps its database open, so it is emptied through
  // its own API first; the loop below then removes what is left on disk.
  [NSURLCache.sharedURLCache removeAllCachedResponses];
  for (NSURL *entry in RFCacheEntries()) [NSFileManager.defaultManager removeItemAtURL:entry error:NULL];
}
