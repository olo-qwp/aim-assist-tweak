#import "AimAssistManager.h"
#import "ESPManager.h"
#import "ScreenScanner.h"

static NSString *const kEnabledKey    = @"AimAssist_Enabled";
static NSString *const kStrengthKey   = @"AimAssist_Strength";
static NSString *const kFovRadiusKey  = @"AimAssist_FovRadius";

@implementation AimAssistManager

+ (instancetype)sharedManager {
    static AimAssistManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[AimAssistManager alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _enabled    = YES;
        _strength   = 0.7f;
        _fovEnabled = YES;
        _fovRadius  = 250.0f;
    }
    return self;
}

- (void)loadSettings {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.aimassist.settings"];
    if ([d objectForKey:kEnabledKey])   _enabled   = [d boolForKey:kEnabledKey];
    if ([d objectForKey:kStrengthKey])  _strength  = [d floatForKey:kStrengthKey];
    if ([d objectForKey:kFovRadiusKey]) _fovRadius = [d floatForKey:kFovRadiusKey];
}

- (void)saveSettings {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.aimassist.settings"];
    [d setBool:_enabled   forKey:kEnabledKey];
    [d setFloat:_strength  forKey:kStrengthKey];
    [d setFloat:_fovRadius forKey:kFovRadiusKey];
    [d synchronize];
}

// ═══════════════════════════════════════════════════════════════════════════
//  核心自瞄逻辑 — v3.0 (ESP驱动)
//
//  原理：
//  1. 从 ESPManager 获取所有敌人数据
//  2. 找到离屏幕中心（准心）最近且在 FOV 范围内的敌人头部
//  3. 计算拉力偏移量：将触摸坐标向敌人头部拉动
//  4. 拉力强度由 strength 控制，最大不超过 head 到 touch 距离的 50%
//
//  与旧版 EMA 平滑的区别：
//  旧版：纯粹的滤波，没有目标检测，只是让触摸更平滑
//  新版：基于实际敌人头部坐标，主动将准心拉向目标
// ═══════════════════════════════════════════════════════════════════════════
- (CGPoint)aimOffsetForTouch:(CGPoint)touch
                   fromPoint:(CGPoint)prevTouch
                  screenSize:(CGSize)screenSize {
    if (!_enabled || _strength <= 0.0f) return CGPointZero;

    // ── 优先：用户选中的模型（准心锁定目标，最高优先级） ──
    ScreenScanner *sc = [ScreenScanner sharedScanner];
    if (sc.hasSelectedModel && sc.selectedConfidence > 0.6f) {
        // 头部位置：锁定框顶部向下 12%（质心偏身体中心，抬到头部更准）
        CGPoint head = sc.selectedModelPos;
        head.y -= sc.selectedModelSize.height * 0.4f;
        CGFloat hdx = head.x - screenSize.width * 0.5f;
        CGFloat hdy = head.y - screenSize.height * 0.5f;
        CGFloat hdist = sqrtf(hdx * hdx + hdy * hdy);
        if (hdist < _fovRadius) {
            return [self pullFromTouch:touch toHead:head];
        }
    }

    ESPManager *esp = [ESPManager sharedManager];
    if (!esp.espEnabled) return CGPointZero;

    NSArray *players = [esp currentPlayers];

    CGFloat cx = screenSize.width  * 0.5f;
    CGFloat cy = screenSize.height * 0.5f;

    // ── 寻找 FOV 内最近的敌人头部 ──
    ESPPlayerData *target = nil;
    CGFloat minDist = _fovRadius;

    for (ESPPlayerData *p in players) {
        if (!p.isValid || !p.isEnemy) continue;
        if (p.health <= 0.0f) continue;

        CGPoint head = p->bonePositions[ESPBoneHead];
        if (head.x <= 0 && head.y <= 0) continue;

        // 计算从屏幕中心（准心）到敌人头部的距离
        CGFloat dx = head.x - cx;
        CGFloat dy = head.y - cy;
        CGFloat dist = sqrtf(dx * dx + dy * dy);

        if (dist < minDist && dist < _fovRadius) {
            minDist = dist;
            target = p;
        }
    }

    if (!target) return CGPointZero;

    CGPoint head = target->bonePositions[ESPBoneHead];
    return [self pullFromTouch:touch toHead:head];
}

// 拉力计算（供选中模型与自动检测共用）
- (CGPoint)pullFromTouch:(CGPoint)touch toHead:(CGPoint)head {
    // 将触摸坐标向敌人头部拉动
    // strength=1.0 时，每帧拉 40% 的距离
    CGFloat pullRatio = _strength * 0.4f;

    // 限制最大拉力，防止瞬移
    CGFloat maxPull = 60.0f + _strength * 40.0f; // 70~100 pts

    CGFloat pullX = (head.x - touch.x) * pullRatio;
    CGFloat pullY = (head.y - touch.y) * pullRatio;

    pullX = MAX(-maxPull, MIN(maxPull, pullX));
    pullY = MAX(-maxPull, MIN(maxPull, pullY));

    // 距离越近拉力越小（防止过冲）
    CGFloat distToHead = sqrtf((head.x - touch.x) * (head.x - touch.x) +
                               (head.y - touch.y) * (head.y - touch.y));
    if (distToHead < 30.0f) {
        CGFloat damp = distToHead / 30.0f;
        pullX *= damp;
        pullY *= damp;
    }

    return CGPointMake(pullX, pullY);
}

- (void)setStrength:(float)s {
    _strength = s;
}

@end