#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AimAssistManager.h"
#import "NativeOverlay.h"

// ── 关联对象 Key ──
//  存储每个 UITouch 上一次滤波后的坐标，用于：
//  1. locationInView: 的 EMA 平滑
//  2. previousLocationInView: 返回一致的值
static const void *kFilteredPointKey = &kFilteredPointKey;

// ── Category 声明（让编译器知道这些方法存在）──
@interface UITouch (AimAssist)
- (void)setFilteredPoint:(CGPoint)pt;
- (CGPoint)getFilteredPoint;
@end

// ═══════════════════════════════════════════════════════════════════════════
//  UITouch 钩子
//  同时 hook locationInView: 和 previousLocationInView: 确保游戏用
//  delta 计算时坐标一致，不会出现跳跃
// ═══════════════════════════════════════════════════════════════════════════
%hook UITouch

// ── 当前坐标 ──
- (CGPoint)locationInView:(UIView *)view {
    CGPoint rawPoint = %orig(view);

    AimAssistManager *mgr = [AimAssistManager sharedManager];
    if (!mgr.enabled || mgr.strength <= 0.0f) {
        return rawPoint;
    }

    UITouchPhase phase = self.phase;

    // Began / Ended / Cancelled → 不滤波，直接返回
    if (phase == UITouchPhaseBegan) {
        // 记录原始点作为滤波起点
        [self setFilteredPoint:rawPoint];
        return rawPoint;
    }
    if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        return rawPoint;
    }

    // Moved / Stationary → 应用滤波
    CGPoint prev = [self getFilteredPoint];
    if (CGPointEqualToPoint(prev, CGPointZero)) {
        prev = rawPoint;
    }

    CGPoint filtered = [mgr processTouchMovement:rawPoint previousPoint:prev];
    [self setFilteredPoint:filtered];
    return filtered;
}

// ── 上一帧坐标 ──
//  游戏经常用 previousLocationInView: - locationInView: 算 delta
//  如果不 hook 这里，delta 会变成 filtered - raw 导致跳跃
- (CGPoint)previousLocationInView:(UIView *)view {
    CGPoint rawPrev = %orig(view);

    AimAssistManager *mgr = [AimAssistManager sharedManager];
    if (!mgr.enabled || mgr.strength <= 0.0f) {
        return rawPrev;
    }

    // 返回我们存储的滤波后的上一帧坐标
    CGPoint filteredPrev = [self getFilteredPoint];
    if (CGPointEqualToPoint(filteredPrev, CGPointZero)) {
        return rawPrev;
    }
    return filteredPrev;
}

// ── 辅助方法：存储/读取滤波坐标 ──
- (void)setFilteredPoint:(CGPoint)pt {
    objc_setAssociatedObject(self,
                             kFilteredPointKey,
                             [NSValue valueWithCGPoint:pt],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (CGPoint)getFilteredPoint {
    NSValue *val = objc_getAssociatedObject(self, kFilteredPointKey);
    return val ? [val CGPointValue] : CGPointZero;
}

%end

// ═══════════════════════════════════════════════════════════════════════════
//  UIApplication 钩子 - 确保浮窗在应用完全启动后显示
// ═══════════════════════════════════════════════════════════════════════════
%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    %orig;
    // 延迟初始化浮窗（只执行一次）
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AimAssistManager sharedManager] loadSettings];
            NativeOverlay *overlay = [NativeOverlay sharedOverlay];
            [overlay show];
        });
    });
}

%end

// ═══════════════════════════════════════════════════════════════════════════
//  构造与析构
// ═══════════════════════════════════════════════════════════════════════════
%ctor {
    @autoreleasepool {
        // 预加载 AimAssistManager（但不初始化 UI，交给 sendEvent:）
        [AimAssistManager sharedManager];
    }
}

%dtor {
    NativeOverlay *overlay = [NativeOverlay sharedOverlay];
    [overlay hide];
}