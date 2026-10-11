// Handler.m
//
// The native half of the "Open in Reddit" Safari extension. Safari requires
// every web extension to ship one; all the work is done by the script in
// Resources/, so this only answers and finishes each request.

#import <Foundation/Foundation.h>

@interface SafariWebExtensionHandler : NSObject <NSExtensionRequestHandling>
@end

@implementation SafariWebExtensionHandler
- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
  [context completeRequestReturningItems:@[] completionHandler:nil];
}
@end
