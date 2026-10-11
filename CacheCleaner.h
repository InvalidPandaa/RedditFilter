// CacheCleaner.h
//
// Size of, and a way to empty, the app's cache folder (downloaded images,
// videos and network responses). Pure Foundation.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Bytes currently used by the files RFClearCache() would delete. Walks the
// folder, so call it off the main thread.
unsigned long long RFCacheSize(void);

// Deletes cached files. Login, settings and drafts live elsewhere and are kept.
void RFClearCache(void);

#ifdef __cplusplus
}
#endif
