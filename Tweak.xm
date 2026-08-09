#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "AimAssistManager.h"
#import "NativeOverlay.h"
#import "ESPManager.h"
#import "EnemyMemoryReader.h"

// ═══════════════════════════════════════════════════════════════════════════
//  v5.0.0 — iGameGod 兼容重构（防闪退 + 去 substrate 依赖）
//
//  核心思路：
//  Unity/IL2CPP 游戏直接访问 UITouch 的内部 ivar _locationInWindow，
//  因此唯一有效的方式是直接修改这个 ivar。
//
//  v5.0.0 变化：
//  - %ctor 纯 C 化：只 fprintf + 8s 兜底 dispatch_after，
//    杜绝 DYLD_INSERT(iGameGod) 场景 dyld 构造阶段碰 ObjC 秒退
//  - 导出 MSInitialize()：注入器在 app 完全启动后调用 → 真正初始化入口
//  - %hook 移除 → ObjC runtime swizzle (method_setImplementation)：
//    零 substrate/ellekit 依赖，iGameGod 非越狱环境直接可用
//  - 跳过 com.apple.* 系统进程（SpringBoard/backboardd 等）
//
//  流程：
//  1. 注入 → %ctor（纯 C）→ 8s 后兜底调度
//  2. MSInitialize / 启动完成通知 → 3s 后主线程初始化
//  3. 初始化：找 ivar 偏移 → swizzle sendEvent → 建 UI → 开扫描器
//  4. sendEvent 中：读 ivar 原始坐标 → 计算拉力 → 写回 ivar
// ═══════════════════════════════════════════════════════════════════════════

// ── Ivar 偏移量 ──
static ptrdiff_t g_locOffset = -1;

// ── 状态 ──
static BOOL g_didInit = NO;   // 幂等；所有路径都 dispatch 到主队列，无竞争
static BOOL g_active  = NO;   // 仅真实游戏 app 置 YES
static IMP  g_origSendEvent = NULL;

// ── Ivar 读写 ──
static void AA_writeIvar(id obj, ptrdiff_t offset, CGPoint val) {
    if (offset < 0) return;
    *(CGPoint *)((char *)(__bridge void *)obj + offset) = val;
}

static CGPoint AA_readIvar(id obj, ptrdiff_t offset) {
    if (offset < 0) return CGPointZero;
    return *(CGPoint *)((char *)(__bridge void *)obj + offset);
}

// ── 运行时查找 UITouch _locationInWindow ivar 偏移量 ──
static void AA_findTouchIvars() {
    if (g_locOffset >= 0) return;
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

    fprintf(stderr, "[AimAssist] ivar offset: %td\n", g_locOffset);
}

// ═══════════════════════════════════════════════════════════════════════════
//  自瞄核心 — 原 %hook sendEvent 逻辑（ESP 驱动）
// ═══════════════════════════════════════════════════════════════════════════
static void AA_handleTouches(UIEvent *event) {
    if (event.type != UIEventTypeTouches || g_locOffset < 0) return;

    AimAssistManager *mgr = [AimAssistManager sharedManager];
    ESPManager *esp = [ESPManager sharedManager];
    if (!mgr.enabled || mgr.strength <= 0.0f || !esp.espEnabled) return;

    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat halfW = screenSize.width * 0.5f;
    CGRect panelFrame = [[NativeOverlay sharedOverlay] panelFrame];

    for (UITouch *touch in [event allTouches]) {
        if (touch.phase != UITouchPhaseMoved) continue;

        // 从 ivar 读取原始坐标
        CGPoint raw = AA_readIvar(touch, g_locOffset);

        // 仅处理右半屏触摸（瞄准区）；多指简化：看当前位置
        if (raw.x < halfW) continue;

        // 跳过控制面板区域的触摸
        if (!CGRectIsNull(panelFrame) && CGRectContainsPoint(panelFrame, raw)) continue;

        // 计算自瞄偏移量（基于 ESP 头部检测）
        CGPoint pull = [mgr aimOffsetForTouch:raw fromPoint:raw screenSize:screenSize];
        if (pull.x != 0.0f || pull.y != 0.0f) {
            AA_writeIvar(touch, g_locOffset, CGPointMake(raw.x + pull.x, raw.y + pull.y));
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  sendEvent swizzle — 纯 ObjC runtime，无需 substrate/ellekit
//  (ponytail: 极少数 app 自定义 UIApplication 子类并覆写 sendEvent: 时
//   基类 swizzle 不生效；罕见，不做处理)
// ═══════════════════════════════════════════════════════════════════════════
static void AA_swizzleSendEvent() {
    Method m = class_getInstanceMethod([UIApplication class], @selector(sendEvent:));
    if (!m || g_origSendEvent) return;
    g_origSendEvent = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self, UIEvent *event) {
        if (g_active) AA_handleTouches(event);
        ((void (*)(id, SEL, UIEvent *))g_origSendEvent)(self, @selector(sendEvent:), event);
    }));
    fprintf(stderr, "[AimAssist] sendEvent swizzled\n");
}

// ═══════════════════════════════════════════════════════════════════════════
//  3s 延迟调度 UI（主线程 + 跳过系统进程 + 幂等）
// ═══════════════════════════════════════════════════════════════════════════
static void AA_scheduleShow() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g_didInit) return;
        if (![UIApplication sharedApplication]) return; // daemon（backboardd 等）无 UIApplication
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid == nil || [bid hasPrefix:@"com.apple."]) return; // 跳过 SpringBoard 等系统进程

        g_didInit = YES;
        g_active  = YES;
        @try {
            AA_findTouchIvars();
            AA_swizzleSendEvent();
            [[AimAssistManager sharedManager] loadSettings];
            [[NativeOverlay sharedOverlay] show];
            // Unity IL2CPP 内存模型敌人检测（后台 10Hz；非 Unity 或未命中自动静默回退屏幕识别）
            [[EnemyMemoryReader sharedReader] start];
            fprintf(stderr, "[AimAssist] init done (%s)\n", bid.UTF8String);
        } @catch (NSException *e) {
            fprintf(stderr, "[AimAssist] init exception: %s\n", e.name.UTF8String);
        }
    });
}

// ═══════════════════════════════════════════════════════════════════════════
//  启动后初始化 — MSInitialize / 启动通知 / 兜底 timer 共用
// ═══════════════════════════════════════════════════════════════════════════
static void AA_runPostLaunchInit() {
    if (g_didInit) return;
    @autoreleasepool {
        // 启动完成通知 → 尽早调度
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            AA_scheduleShow();
        }];
        AA_scheduleShow();
    }
}

// ── 注入器约定的启动入口（MobileLoader / iGameGod 在 app 启动后 dlsym 调用） ──
extern "C" void MSInitialize(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AA_runPostLaunchInit();
    });
}

// ═══════════════════════════════════════════════════════════════════════════
//  纯 C constructor — iGameGod(DYLD_INSERT) 场景下唯一安全操作：
//  只 fprintf + dispatch_after(C API)，任何 ObjC 都会在 main() 前崩溃
// ═══════════════════════════════════════════════════════════════════════════
%ctor {
    fprintf(stderr, "[AimAssist] ctor pid=%d\n", (int)getpid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AA_runPostLaunchInit();
    });
}
