#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@class ESPManager;

@interface NativeOverlay : NSObject

+ (instancetype)sharedOverlay;
- (void)show;
- (void)hide;
- (BOOL)isVisible;
- (void)setNeedsDisplay;

// 控制面板 frame（用于触摸穿透判断）
- (CGRect)panelFrame;

@end