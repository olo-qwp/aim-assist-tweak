#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AimAssistManager.h"
#import "NativeOverlay.h"
#import "ESPManager.h"
#import "ScreenScanner.h"

// ═══════════════════════════════════════════════════════════════════════════
//  Ivar 修改架构 — v3.0 (ESP驱动自瞄)
//
//  核心思路：
//  Unity/IL2CPP 游戏直接访问 UITouch 的内部 ivar _locationInWindow，
//  因此唯一有效的方式是直接修改这个 ivar。
//
//  v3.0 变化：
//  - 不再使用 EMA 平滑滤波 + 中心拉力
//  - 改为基于 ESP 数据的头部检测 + 目标拉力
//  - 自瞄逻辑：找到最近敌人头部 → 计算偏移 → 修改 ivar
//
//  流程：
//  1. sendEvent: 中读取 ivar 原始值
//  2. 从 ESPManager 获取敌人头部坐标
//  3. 计算拉力偏移量
//  4. 写回 ivar
// ═══════════════════════════════════════════════════════════════════════════

// ── Ivar 偏移量 ──
static ptrdiff_t g_locOffset = -1;

// ── Ivar 读写 ──
static void aa_writeIvar(id obj, ptrdiff_t offset, CGPoint val) {
    if (offset < 0) return;
    *(CGPoint *)((char *)(__bridge void *)obj + offset) = val;
}

static CGPoint aa_readIvar(id obj, ptrdiff_t offset) {
    if (offset < 0) return CGPointZero;
    return *(CGPoint *)((char *)(__bridge void *)obj + offset);
}

// ── 运行时查找 UITouch _locationInWindow ivar 偏移量 ──
static void aa_findTouchIvars() {
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([UITouch class], &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        if (!name) continue;
        if (strcmp(name, "_locationInWindow") == 0) {
            g_locOffset = ivar_getOffset(ivars[i]);
            break;
        }
    }
    free(ivars);

    // 模糊匹配兜底
    if (g_locOffset < 0) {
        ivars = class_copyIvarList([UITouch class], &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            if (!name) continue;
            if (strstr(name, "locationInWindow") && !strstr(name, "previous")) {
                g_locOffset = ivar_getOffset(ivars[i]);
                break;
            }
        }
        free(ivars);
    }

    NSLog(@"[AimAssist] ivar offset: _locationInWindow=%td", g_locOffset);
}

// ═══════════════════════════════════════════════════════════════════════════
//  UIApplication sendEvent: — 唯一入口
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

    if (event.type == UIEventTypeTouches && g_locOffset >= 0) {
        AimAssistManager *mgr = [AimAssistManager sharedManager];
        ESPManager *esp = [ESPManager sharedManager];
        CGSize screenSize = [UIScreen mainScreen].bounds.size;

        if (mgr.enabled && mgr.strength > 0.0f && esp.espEnabled) {
            CGFloat halfW = screenSize.width * 0.5f;
            CGRect panelFrame = [[NativeOverlay sharedOverlay] panelFrame];

            for (UITouch *touch in [event allTouches]) {
                if (touch.phase == UITouchPhaseBegan) {
                    // 保存起始触摸位置，用于判断左右半屏
                    // 使用关联对象，无需额外开销
                    continue;
                }

                if (touch.phase != UITouchPhaseMoved) continue;

                // 从 ivar 读取原始坐标
                CGPoint raw = aa_readIvar(touch, g_locOffset);

                // ── 仅处理右半屏起始的触摸（瞄准区） ──
                // 注意：对于单指操作，我们检查当前位置是否在右半屏
                // 如果是多指，应检查起始触摸位置
                // 简化处理：检查当前触摸 X > 屏幕一半
                if (raw.x < halfW) continue;

                // ── 跳过控制面板区域的触摸 ──
                if (!CGRectIsNull(panelFrame) && CGRectContainsPoint(panelFrame, raw)) {
                    continue;
                }

                // ── 计算自瞄偏移量（基于ESP头部检测） ──
                CGPoint pull = [mgr aimOffsetForTouch:raw
                                            fromPoint:raw
                                           screenSize:screenSize];

                if (pull.x != 0.0f || pull.y != 0.0f) {
                    CGPoint filtered = CGPointMake(raw.x + pull.x, raw.y + pull.y);
                    aa_writeIvar(touch, g_locOffset, filtered);
                }
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
        [ESPManager sharedManager];
        [ScreenScanner sharedScanner];
    }
}

%dtor {
    [[NativeOverlay sharedOverlay] hide];
    [[ScreenScanner sharedScanner] stopScanning];
}