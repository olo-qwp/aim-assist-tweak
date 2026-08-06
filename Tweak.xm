#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AimAssistManager.h"
#import "NativeOverlay.h"

// ═══════════════════════════════════════════════════════════════════════════
//  Ivar 直接修改方案 — 核心设计
//
//  Unity 引擎可能通过以下任一方式读取触摸坐标：
//    1. [touch locationInView:view]   → 内部读取 _locationInWindow ivar
//    2. [touch _locationInWindow]      → 私有方法，读取同一 ivar
//    3. 直接访问 _locationInWindow ivar → 绕过所有方法
//
//  因此，hook locationInView: 不够可靠。
//  正确做法：在 sendEvent: 中直接修改 UITouch 的内部 ivar：
//    _locationInWindow          ← 当前帧滤波值
//    _previousLocationInWindow  ← 上一帧滤波值
//
//  这样无论 Unity 用什么方式读取，拿到的都是滤波后的坐标。
//  locationInView: / previousLocationInView: 无需 hook，它们自动读取修改后的 ivar。
// ═══════════════════════════════════════════════════════════════════════════

// 关联对象：存储每个 touch 上一帧的滤波输出
static const void *kPrevFilteredKey = &kPrevFilteredKey;

// UITouch 内部 ivar 的内存偏移量（运行时查找）
static ptrdiff_t g_locOffset     = -1;  // _locationInWindow
static ptrdiff_t g_prevLocOffset = -1;  // _previousLocationInWindow

// ── 直接读写 ivar 内存 ──
static CGPoint aa_readIvar(id obj, ptrdiff_t offset) {
    if (offset < 0) return CGPointZero;
    return *(CGPoint *)((char *)(__bridge void *)obj + offset);
}

static void aa_writeIvar(id obj, ptrdiff_t offset, CGPoint val) {
    if (offset < 0) return;
    *(CGPoint *)((char *)(__bridge void *)obj + offset) = val;
}

// ── 运行时查找 UITouch 的内部 ivar 偏移量 ──
static void aa_findTouchIvars() {
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([UITouch class], &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (!name || !type || type[0] != '{') continue;

        if (strcmp(name, "_locationInWindow") == 0) {
            g_locOffset = ivar_getOffset(ivars[i]);
        } else if (strcmp(name, "_previousLocationInWindow") == 0) {
            g_prevLocOffset = ivar_getOffset(ivars[i]);
        }
    }
    free(ivars);

    // 兼容不同 iOS 版本的备用名称
    if (g_locOffset < 0 || g_prevLocOffset < 0) {
        ivars = class_copyIvarList([UITouch class], &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!name || !type || type[0] != '{') continue;

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
//  UIApplication sendEvent: — 在系统更新 ivar 后、Unity 读取前修改
//
//  时序：
//    1. 系统更新 _locationInWindow = 新原始坐标，_previousLocationInWindow = 上一帧原始坐标
//    2. sendEvent: 被调用（我们的 hook）
//    3. 我们读取 _locationInWindow（原始值），计算滤波，覆写两个 ivar
//    4. %orig 执行 → Unity 读取 touch 坐标 → 拿到滤波后的值 ✓
// ═══════════════════════════════════════════════════════════════════════════
%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    // ── 初始化（只一次） ──
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
        if (mgr.enabled && mgr.strength > 0.0f && g_locOffset >= 0) {
            for (UITouch *touch in [event allTouches]) {
                UITouchPhase phase = touch.phase;

                if (phase == UITouchPhaseBegan) {
                    // 初始化：记录原始坐标作为上一帧滤波值
                    CGPoint raw = aa_readIvar(touch, g_locOffset);
                    if (CGPointEqualToPoint(raw, CGPointZero)) {
                        raw = [touch locationInView:nil];
                    }
                    objc_setAssociatedObject(touch, kPrevFilteredKey,
                        [NSValue valueWithCGPoint:raw],
                        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    continue;
                }

                if (phase != UITouchPhaseMoved) continue;

                // ── 读取原始坐标（系统刚写入 _locationInWindow） ──
                CGPoint raw = aa_readIvar(touch, g_locOffset);
                if (CGPointEqualToPoint(raw, CGPointZero)) {
                    raw = [touch locationInView:nil];
                }

                // ── 读取上一帧滤波值 ──
                NSValue *prevVal = objc_getAssociatedObject(touch, kPrevFilteredKey);
                CGPoint prev = prevVal ? [prevVal CGPointValue] : raw;

                // ── EMA 滤波 + 中心拉力 ──
                CGPoint filtered = [mgr processTouchMovement:raw previousPoint:prev];

                // ── 存储当前滤波值供下一帧使用 ──
                objc_setAssociatedObject(touch, kPrevFilteredKey,
                    [NSValue valueWithCGPoint:filtered],
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                // ── 覆写 UITouch 内部 ivar ──
                // _locationInWindow ← 滤波后坐标
                // _previousLocationInWindow ← 上一帧滤波后坐标
                // 这样 locationInView: / previousLocationInView: / _locationInWindow
                // 等所有方法都会自动返回滤波后的值
                aa_writeIvar(touch, g_locOffset, filtered);
                aa_writeIvar(touch, g_prevLocOffset, prev);
            }
        }
    }

    %orig;
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
