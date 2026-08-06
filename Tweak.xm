#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AimAssistManager.h"
#import "ImGuiOverlay.h"

// ── 关联对象 Key：存储每个 UITouch 上一次的滤波坐标 ──
static const void *kLastFilteredPointKey = &kLastFilteredPointKey;

// ── 钩子：拦截 UITouch 的触摸坐标，施加平滑滤波 ──
%hook UITouch

- (CGPoint)locationInView:(UIView *)view {
    CGPoint rawPoint = %orig;

    AimAssistManager *mgr = [AimAssistManager sharedManager];
    if (!mgr.enabled || mgr.strength <= 0.0f) {
        return rawPoint;
    }

    UITouchPhase phase = self.phase;

    if (phase == UITouchPhaseBegan) {
        // 第一帧直接记录原始坐标，不做平滑
        objc_setAssociatedObject(self,
                                 kLastFilteredPointKey,
                                 [NSValue valueWithCGPoint:rawPoint],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return rawPoint;
    }

    if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        return rawPoint;
    }

    // UITouchPhaseMoved / UITouchPhaseStationary：应用平滑
    NSValue *lastValue = objc_getAssociatedObject(self, kLastFilteredPointKey);
    CGPoint lastPoint = lastValue ? [lastValue CGPointValue] : rawPoint;

    CGPoint filteredPoint = [mgr processTouchMovement:rawPoint previousPoint:lastPoint];

    objc_setAssociatedObject(self,
                             kLastFilteredPointKey,
                             [NSValue valueWithCGPoint:filteredPoint],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    return filteredPoint;
}

%end

// ── 构造与析构：注入时启动浮窗，卸载时关闭 ──
static ImGuiOverlay *overlay = nil;

%ctor {
    @autoreleasepool {
        [[AimAssistManager sharedManager] loadSettings];

        // 延迟初始化浮窗，等待应用 UI 完全就绪
        // 避免在 %ctor 早期阶段 Metal/UIKit 未初始化导致崩溃
        dispatch_async(dispatch_get_main_queue(), ^{
            // 额外等待一帧，确保 UIWindow 层级已创建
            dispatch_async(dispatch_get_main_queue(), ^{
                overlay = [ImGuiOverlay sharedOverlay];
                [overlay show];
            });
        });
    }
}

%dtor {
    [overlay hide];
    overlay = nil;
}