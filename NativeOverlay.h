#import <UIKit/UIKit.h>

@interface NativeOverlay : NSObject

+ (instancetype)sharedOverlay;
- (void)show;
- (void)hide;
- (BOOL)isVisible;

@end