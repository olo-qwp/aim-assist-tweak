#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AimAssistManager.h"
#import "NativeOverlay.h"

// ═══════════════════════════════════════════════════════════════════════════
//  双路径触摸修改 — 全覆盖架构
//
//  路径A：方法Hook（locationInView: / previousLocationInView: / precise* 变体）
//    → 适用于通过公开API读取坐标的游戏
//
//  路径B：Ivar直接修改（_locationInWindow / _previousLocationInWindow）
//    → 适用于直接读取内部ivar的游戏
//
//  两条路径同时工作，确保无论游戏用哪种方式读取，都能拿到滤波后的值。
//
//  偏移量系统：不修改绝对坐标，只计算 offset = filtered - raw
//    locationInView:        返回 %orig(view) + offset
//    previousLocationInView: 返回 %orig(view) + prevOffset
//    → 坐标转换由 %orig 处理，兼容所有view坐标系
//    → delta = (raw+offset) - (rawPrev+prevOffset) = filteredCurr - filteredPrev ✓
//
//  仅处理右半屏起始的触摸（瞄准区），左半屏（移动摇杆）不修改。
// ═══════════════════════════════════════════════════════════════════════════

// ── 关联对象 Key ──
static const void *kOffsetKey       = &kOffsetKey;       // 当前帧偏移
static const void *kPrevOffsetKey   = &kPrevOffsetKey;   // 上一帧偏移
static const void *kPrevFilteredKey = &kPrevFilteredKey; // 上一帧滤波值
static const void *kStartXKey       = &kStartXKey;       // 触摸起始X（判断左右半屏）

// ── 处理标志 ──
// sendEvent: 期间设为 YES，使方法hook返回原始值（%orig）
static BOOL g_isProcessing = NO;

// ── Ivar 偏移量 ──
static ptrdiff_t g_locOffset     = -1;
static ptrdiff_t g_prevLocOffset = -1;

// ── Ivar 写入（读取不需要，方法hook的%orig会处理） ──
static void aa_writeIvar(id obj, ptrdiff_t offset, CGPoint val) {
    if (offset < 0) return;
    *(CGPoint *)((char *)(__bridge void *)obj + offset) = val;
}

// ── 关联对象读写 ──
static CGPoint aa_getPoint(id obj, const void *key) {
    NSValue *v = objc_getAssociatedObject(obj, key);
    return v ? [v CGPointValue] : CGPointZero;
}

static void aa_setPoint(id obj, const void *key, CGPoint p) {
    objc_setAssociatedObject(obj, key,
                             [NSValue valueWithCGPoint:p],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ── 运行时查找 UITouch ivar 偏移量（无类型检查，更宽松） ──
static void aa_findTouchIvars() {
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([UITouch class], &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        if (!name) continue;

        if (strcmp(name, "_locationInWindow") == 0) {
            g_locOffset = ivar_getOffset(ivars[i]);
        } else if (strcmp(name, "_previousLocationInWindow") == 0) {
            g_prevLocOffset = ivar_getOffset(ivars[i]);
        }
    }
    free(ivars);

    // 模糊匹配兜底
    if (g_locOffset < 0 || g_prevLocOffset < 0) {
        ivars = class_copyIvarList([UITouch class], &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            if (!name) continue;

            if (g_locOffset < 0 && strstr(name, "locationInWindow") && !strstr(name, "previous")) {
                g_locOffset = ivar_getOffset(ivars[i]);
            }
            if (g_prevLocOffset < 0 && strstr(name, "previousLocationInWindow")) {
                g_prevLocOffset = ivar_getOffset(ivars[i]);
            }
        }
        free(ivars);
    }

    NSLog(@"[AimAssist] ivar offsets: loc=%td, prevLoc=%td", g_locOffset, g_prevLocOffset);
}

// ═══════════════════════════════════════════════════════════════════════════
//  UIApplication sendEvent: — 预计算偏移量 + 修改 ivar
// ═══════════════════════════════════════════════════════════════════════════
%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        aa_findTouchIvars();
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AimAssistManager sharedManager] loadSettings];
            [[NativeOverlay sharedOverlay] show];
        });
    });

    if (event.type == UIEventTypeTouches) {
        AimAssistManager *mgr = [AimAssistManager sharedManager];
        if (mgr.enabled && mgr.strength > 0.0f) {
            CGFloat halfW = [UIScreen mainScreen].bounds.size.width * 0.5f;
            CGRect panelFrame = [[NativeOverlay sharedOverlay] panelFrame];

            g_isProcessing = YES;

            for (UITouch *touch in [event allTouches]) {
                UITouchPhase phase = touch.phase;

                // 获取原始坐标（g_isProcessing=YES 时 hook 返回 %orig）
                CGPoint raw = [touch locationInView:nil];

                if (phase == UITouchPhaseBegan) {
                    // 记录起始位置
                    aa_setPoint(touch, kStartXKey, raw);
                    aa_setPoint(touch, kPrevFilteredKey, raw);
                    aa_setPoint(touch, kOffsetKey, CGPointZero);
                    aa_setPoint(touch, kPrevOffsetKey, CGPointZero);
                    continue;
                }

                if (phase != UITouchPhaseMoved) continue;

                // ── 仅处理右半屏起始的触摸（瞄准区） ──
                CGFloat startX = aa_getPoint(touch, kStartXKey).x;
                if (startX < halfW) {
                    // 左半屏（移动摇杆）：不滤波
                    aa_setPoint(touch, kOffsetKey, CGPointZero);
                    aa_setPoint(touch, kPrevOffsetKey, CGPointZero);
                    aa_setPoint(touch, kPrevFilteredKey, raw);
                    continue;
                }

                // ── 跳过控制面板区域的触摸 ──
                if (!CGRectIsNull(panelFrame) && CGRectContainsPoint(panelFrame, raw)) {
                    aa_setPoint(touch, kOffsetKey, CGPointZero);
                    aa_setPoint(touch, kPrevOffsetKey, CGPointZero);
                    aa_setPoint(touch, kPrevFilteredKey, raw);
                    continue;
                }

                // ── 移位：当前偏移 → 上一帧偏移 ──
                CGPoint prevOffset = aa_getPoint(touch, kOffsetKey);
                aa_setPoint(touch, kPrevOffsetKey, prevOffset);

                // ── EMA 滤波 ──
                CGPoint prevFiltered = aa_getPoint(touch, kPrevFilteredKey);
                if (CGPointEqualToPoint(prevFiltered, CGPointZero)) prevFiltered = raw;

                CGPoint filtered = [mgr processTouchMovement:raw previousPoint:prevFiltered];

                aa_setPoint(touch, kPrevFilteredKey, filtered);

                // ── 计算偏移量 = filtered - raw ──
                CGPoint offset = CGPointMake(filtered.x - raw.x, filtered.y - raw.y);
                aa_setPoint(touch, kOffsetKey, offset);

                // ── 路径B：同时修改 ivar（不依赖 offset >= 0） ──
                aa_writeIvar(touch, g_locOffset, filtered);
                aa_writeIvar(touch, g_prevLocOffset, prevFiltered);
            }

            g_isProcessing = NO;
        }
    }

    %orig;
}

%end

// ═══════════════════════════════════════════════════════════════════════════
//  UITouch 方法Hook — 路径A
//  覆盖所有公开/精确变体，确保任何调用路径都返回滤波值
// ═══════════════════════════════════════════════════════════════════════════
%hook UITouch

// ── locationInView: ──
- (CGPoint)locationInView:(UIView *)view {
    if (g_isProcessing || self.phase != UITouchPhaseMoved) {
        return %orig(view);
    }
    CGPoint raw = %orig(view);
    CGPoint offset = aa_getPoint(self, kOffsetKey);
    if (CGPointEqualToPoint(offset, CGPointZero)) return raw;
    return CGPointMake(raw.x + offset.x, raw.y + offset.y);
}

// ── previousLocationInView: ──
- (CGPoint)previousLocationInView:(UIView *)view {
    if (g_isProcessing || self.phase != UITouchPhaseMoved) {
        return %orig(view);
    }
    CGPoint rawPrev = %orig(view);
    CGPoint prevOffset = aa_getPoint(self, kPrevOffsetKey);
    if (CGPointEqualToPoint(prevOffset, CGPointZero)) return rawPrev;
    return CGPointMake(rawPrev.x + prevOffset.x, rawPrev.y + prevOffset.y);
}

// ── preciseLocationInView: (iOS 9.1+) ──
- (CGPoint)preciseLocationInView:(UIView *)view {
    if (g_isProcessing || self.phase != UITouchPhaseMoved) {
        return %orig(view);
    }
    CGPoint raw = %orig(view);
    CGPoint offset = aa_getPoint(self, kOffsetKey);
    if (CGPointEqualToPoint(offset, CGPointZero)) return raw;
    return CGPointMake(raw.x + offset.x, raw.y + offset.y);
}

// ── precisePreviousLocationInView: (iOS 9.1+) ──
- (CGPoint)precisePreviousLocationInView:(UIView *)view {
    if (g_isProcessing || self.phase != UITouchPhaseMoved) {
        return %orig(view);
    }
    CGPoint rawPrev = %orig(view);
    CGPoint prevOffset = aa_getPoint(self, kPrevOffsetKey);
    if (CGPointEqualToPoint(prevOffset, CGPointZero)) return rawPrev;
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
