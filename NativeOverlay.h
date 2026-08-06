#import <UIKit/UIKit.h>

@interface NativeOverlay : NSObject

+ (instancetype)sharedOverlay;
- (void)show;
- (void)hide;
- (BOOL)isVisible;

// 返回控制面板在屏幕上的 frame（用于触摸穿透判断）
- (CGRect)panelFrame;

@end
