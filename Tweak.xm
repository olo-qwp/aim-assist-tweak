#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AimAssistManager.h"
#import "NativeOverlay.h"

// ═══════════════════════════════════════════════════════════════════════════
//  偏移量系统 — 核心设计
//
//  不修改触摸的绝对坐标，而是计算一个"偏移量"：
//    offset = filteredPosition - rawPosition
//
//  locationInView:        返回 raw + offset     （滤波后位置）
//  previousLocationInView: 返回 rawPrev + prevOffset（上一帧滤波后位置）
//
//  游戏看到的 delta = locationInView - previousLocationInView
//                   = (raw + offset) - (rawPrev + prevOffset)
//                   = (raw - rawPrev) + (offset - prevOffset)
//                   = filteredCurr - filteredPrev  ← 正确的 EMA delta
//
//  优势：
//  - 绝对位置始终接近手指真实位置（offset 很小）
//  - delta 计算正确，不返回 0
//  - 坐标转换由 %orig 处理，兼容所有 view 坐标系
//  - 仅影响右半屏起始的触摸（瞄准区），左半屏（移动摇杆）不受影响
// ═══════════════════════════════════════════════════════════════════════════

// 关联对象 Key
static const void *kOffsetKey       = &kOffsetKey;        // 当前帧偏移
static const void *kPrevOffsetKey   = &kPrevOffsetKey;    // 上一帧偏移
static const void *kPrevFilteredKey = &kPrevFilteredKey;  // 上一帧滤波值（供 EMA 用）
static const void *kStartXKey       = &kStartXKey;        // 触摸起始 X（判断左右半屏）

// 处理标志：sendEvent: 期间获取原始坐标时设为 YES
static BOOL g_isProcessing = NO;

// ═══════════════════════════════════════════════════════════════════════════
//  UITouch Category — 关联对象读写
// ═══════════════════════════════════════════════════════════════════════════
@interface UITouch (AimAssist)
@property (nonatomic, assign) CGPoint aa_offset;
@property (nonatomic, assign) CGPoint aa_prevOffset;
@property (nonatomic, assign) CGPoint aa_prevFiltered;
@property (nonatomic, assign) CGFloat  aa_startX;
@end

@implementation UITouch (AimAssist)

- (CGPoint)aa_offset {
    NSValue *v = objc_getAssociatedObject(self, kOffsetKey);
    return v ? [v CGPointValue] : CGPointZero;
}
- (void)setAa_offset:(CGPoint)p {
    objc_setAssociatedObject(self, kOffsetKey,
                             [NSValue valueWithCGPoint:p], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (CGPoint)aa_prevOffset {
    NSValue *v = objc_getAssociatedObject(self, kPrevOffsetKey);
    return v ? [v CGPointValue] : CGPointZero;
}
- (void)setAa_prevOffset:(CGPoint)p {
    objc_setAssociatedObject(self, kPrevOffsetKey,
                             [NSValue valueWithCGPoint:p], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (CGPoint)aa_prevFiltered {
    NSValue *v = objc_getAssociatedObject(self, kPrevFilteredKey);
    return v ? [v CGPointValue] : CGPointZero;
}
- (void)setAa_prevFiltered:(CGPoint)p {
    objc_setAssociatedObject(self, kPrevFilteredKey,
                             [NSValue valueWithCGPoint:p], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (CGFloat)aa_startX {
    NSNumber *n = objc_getAssociatedObject(self, kStartXKey);
    return n ? n.floatValue : -1;
}
- (void)setAa_startX:(CGFloat)x {
    objc_setAssociatedObject(self, kStartXKey, @(x), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

// ═══════════════════════════════════════════════════════════════════════════
//  UIApplication sendEvent: — 预计算偏移量
//
//  在游戏处理触摸之前：
//  1. 获取每个触摸的原始坐标（g_isProcessing=YES 使 hook 返回原始值）
//  2. 判断是否为瞄准触摸（右半屏起始）
//  3. 计算 EMA 滤波 + 中心拉力
//  4. 存储偏移量 = filtered - raw
//  5. 移位：prevOffset = offset（供 previousLocationInView: 使用）
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

    // ── 预处理触摸 ──
    if (event.type == UIEventTypeTouches) {
        AimAssistManager *mgr = [AimAssistManager sharedManager];
        if (mgr.enabled && mgr.strength > 0.0f) {
            CGSize screen = [UIScreen mainScreen].bounds.size;
            CGFloat halfW = screen.width * 0.5f;

            // 获取面板 frame（用于跳过面板触摸）
            CGRect panelFrame = [[NativeOverlay sharedOverlay] panelFrame];

            // 标志置 YES：使 locationInView: hook 返回原始坐标
            g_isProcessing = YES;

            for (UITouch *touch in [event allTouches]) {
                UITouchPhase phase = touch.phase;

                // 获取原始坐标（g_isProcessing=YES 时 hook 直接返回 %orig）
                CGPoint raw = [touch locationInView:touch.view];

                if (phase == UITouchPhaseBegan) {
                    // 记录起始位置，判断是否为瞄准触摸
                    touch.aa_startX = raw.x;
                    touch.aa_prevFiltered = raw;
                    touch.aa_offset = CGPointZero;
                    touch.aa_prevOffset = CGPointZero;
                    continue;
                }

                if (phase != UITouchPhaseMoved) continue;

                // ── 跳过非瞄准触摸（左半屏起始 = 移动摇杆） ──
                if (touch.aa_startX < halfW) {
                    // 移动触摸：不做任何滤波，偏移归零
                    touch.aa_offset = CGPointZero;
                    touch.aa_prevOffset = CGPointZero;
                    touch.aa_prevFiltered = raw;
                    continue;
                }

                // ── 跳过控制面板区域的触摸 ──
                if (!CGRectIsNull(panelFrame)) {
                    // 将 raw 转换到窗口坐标系（面板 frame 在 OverlayWindow 坐标系）
                    CGPoint rawInWin;
                    if (touch.view) {
                        rawInWin = [touch.view convertPoint:raw toView:nil];
                    } else {
                        rawInWin = raw;
                    }
                    if (CGRectContainsPoint(panelFrame, rawInWin)) {
                        touch.aa_offset = CGPointZero;
                        touch.aa_prevOffset = CGPointZero;
                        touch.aa_prevFiltered = raw;
                        continue;
                    }
                }

                // ── 移位：当前偏移 → 上一帧偏移 ──
                touch.aa_prevOffset = touch.aa_offset;

                // ── EMA 滤波 ──
                CGPoint prevFiltered = touch.aa_prevFiltered;
                if (CGPointEqualToPoint(prevFiltered, CGPointZero)) prevFiltered = raw;

                CGPoint filtered = [mgr processTouchMovement:raw previousPoint:prevFiltered];

                // ── 计算偏移量 = filtered - raw ──
                touch.aa_offset = CGPointMake(filtered.x - raw.x, filtered.y - raw.y);
                touch.aa_prevFiltered = filtered;
            }

            // 标志置 NO：后续游戏调用 locationInView: 时返回滤波值
            g_isProcessing = NO;
        }
    }

    %orig;
}

%end

// ═══════════════════════════════════════════════════════════════════════════
//  UITouch locationInView: — 返回 raw + offset
//  Unity 通过此方法读取触摸坐标
// ═══════════════════════════════════════════════════════════════════════════
%hook UITouch

- (CGPoint)locationInView:(UIView *)view {
    // 处理中或非 Moved 阶段：返回原始值
    if (g_isProcessing || self.phase != UITouchPhaseMoved) {
        return %orig(view);
    }

    CGPoint raw = %orig(view);
    CGPoint offset = self.aa_offset;

    // 偏移为零 = 不滤波
    if (CGPointEqualToPoint(offset, CGPointZero)) {
        return raw;
    }

    return CGPointMake(raw.x + offset.x, raw.y + offset.y);
}

// previousLocationInView: — 返回 rawPrev + prevOffset
// 确保 Unity 的 delta = location - previousLocation 计算正确
- (CGPoint)previousLocationInView:(UIView *)view {
    if (g_isProcessing || self.phase != UITouchPhaseMoved) {
        return %orig(view);
    }

    CGPoint rawPrev = %orig(view);
    CGPoint prevOffset = self.aa_prevOffset;

    if (CGPointEqualToPoint(prevOffset, CGPointZero)) {
        return rawPrev;
    }

    return CGPointMake(rawPrev.x + prevOffset.x, rawPrev.y + prevOffset.y);
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
