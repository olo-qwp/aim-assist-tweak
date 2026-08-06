#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AimAssistManager.h"
#import "NativeOverlay.h"

// ═══════════════════════════════════════════════════════════════════════════
//  存储每个 UITouch 上一帧的滤波输出
//  每次 locationInView: ：
//    1. 读取此值作为 previousPoint
//    2. 计算滤波后的坐标
//    3. 将滤波结果存回，作为下一帧的 previousPoint
//  previousLocationInView: 直接返回此值
// ═══════════════════════════════════════════════════════════════════════════
static const void *kLastFilteredKey = &kLastFilteredKey;

// ═══════════════════════════════════════════════════════════════════════════
//  UITouch Category — 辅助读写
// ═══════════════════════════════════════════════════════════════════════════
@interface UITouch (AimAssist)
@property (nonatomic, assign) CGPoint aa_lastFiltered;
@end

@implementation UITouch (AimAssist)

- (CGPoint)aa_lastFiltered {
    NSValue *v = objc_getAssociatedObject(self, kLastFilteredKey);
    return v ? [v CGPointValue] : CGPointZero;
}

- (void)setAa_lastFiltered:(CGPoint)p {
    objc_setAssociatedObject(self, kLastFilteredKey,
                             [NSValue valueWithCGPoint:p],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

// ═══════════════════════════════════════════════════════════════════════════
//  UIApplication sendEvent: — 在 Unity 处理触摸事件前预计算滤波值
//  遍历所有 UITouch，计算出滤波后的坐标并存储到 touch.aa_lastFiltered
//  然后调用 %orig 让 Unity 处理事件，Unity 在 locationInView: 中拿到滤波值
// ═══════════════════════════════════════════════════════════════════════════
%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    // ── 初始化浮窗（只一次） ──
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AimAssistManager sharedManager] loadSettings];
            [[NativeOverlay sharedOverlay] show];
        });
    });

    // ── 预处理触摸事件 ──
    if (event.type == UIEventTypeTouches) {
        AimAssistManager *mgr = [AimAssistManager sharedManager];
        if (mgr.enabled && mgr.strength > 0.0f) {
            NSSet<UITouch *> *touches = [event allTouches];
            for (UITouch *touch in touches) {
                UITouchPhase phase = touch.phase;
                CGPoint raw = [touch locationInView:touch.view];

                if (phase == UITouchPhaseBegan) {
                    // 第一帧：存储原始坐标，不做滤波
                    touch.aa_lastFiltered = raw;
                } else if (phase == UITouchPhaseMoved) {
                    // 读取上一帧的滤波输出作为 previousPoint
                    CGPoint prev = touch.aa_lastFiltered;
                    if (CGPointEqualToPoint(prev, CGPointZero)) prev = raw;

                    // 计算滤波
                    CGPoint filtered = [mgr processTouchMovement:raw
                                                   previousPoint:prev];
                    // 存储滤波值供下一帧和 locationInView: 使用
                    touch.aa_lastFiltered = filtered;
                }
                // Ended / Cancelled：不处理
            }
        }
    }

    %orig;
}

%end

// ═══════════════════════════════════════════════════════════════════════════
//  UITouch locationInView: — 返回预计算的滤波值
//  Unity 在此方法中读取触摸坐标，返回我们预先算好的滤波值
// ═══════════════════════════════════════════════════════════════════════════
%hook UITouch

- (CGPoint)locationInView:(UIView *)view {
    if (self.phase == UITouchPhaseBegan ||
        self.phase == UITouchPhaseEnded ||
        self.phase == UITouchPhaseCancelled) {
        return %orig(view);
    }

    // 返回预计算的滤波值
    CGPoint filtered = self.aa_lastFiltered;
    if (CGPointEqualToPoint(filtered, CGPointZero)) {
        return %orig(view);
    }
    return filtered;
}

//  previousLocationInView: — 返回上一帧的滤波值
//  确保 Unity 的 delta = location - previousLocation 计算正确
- (CGPoint)previousLocationInView:(UIView *)view {
    // 返回之前存储的滤波值（即上一帧的实际输出）
    CGPoint prev = self.aa_lastFiltered;
    if (CGPointEqualToPoint(prev, CGPointZero)) {
        return %orig(view);
    }
    return prev;
}

%end

// ═══════════════════════════════════════════════════════════════════════════
%ctor {
    @autoreleasepool {
        [AimAssistManager sharedManager];
    }
}

%dtor {
    [[NativeOverlay sharedOverlay] hide];
}