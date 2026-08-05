#import <UIKit/UIKit.h>

@interface ImGuiOverlay : NSObject

+ (instancetype)sharedOverlay;
- (void)show;
- (void)hide;
- (BOOL)isVisible;

@end