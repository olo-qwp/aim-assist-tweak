#import "AimAssistManager.h"

static NSString *const kEnabledKey            = @"AimAssist_Enabled";
static NSString *const kStrengthKey           = @"AimAssist_Strength";
static NSString *const kFovEnabledKey         = @"AimAssist_FovEnabled";
static NSString *const kFovRadiusKey          = @"AimAssist_FovRadius";
static NSString *const kSnapToCenterKey       = @"AimAssist_SnapToCenter";
static NSString *const kCenterPullStrengthKey = @"AimAssist_CenterPullStrength";
static NSString *const kHeadshotModeKey       = @"AimAssist_HeadshotMode";
static NSString *const kHeadshotSnapRadiusKey = @"AimAssist_HeadshotSnapRadius";

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
        _enabled            = YES;
        _strength           = 0.6f;           // 60%
        _smoothingFactor    = 0.21f;          // strength * 0.35
        _fovEnabled         = YES;
        _fovRadius          = 200.0f;
        _snapToCenter       = YES;
        _centerPullStrength = 0.5f;           // 50%
        _headshotMode       = NO;
        _headshotSnapRadius = 30.0f;
    }
    return self;
}

- (void)loadSettings {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.aimassist.settings"];
    if ([d objectForKey:kEnabledKey])            _enabled            = [d boolForKey:kEnabledKey];
    if ([d objectForKey:kStrengthKey])           _strength           = [d floatForKey:kStrengthKey];
    if ([d objectForKey:kFovEnabledKey])         _fovEnabled         = [d boolForKey:kFovEnabledKey];
    if ([d objectForKey:kFovRadiusKey])          _fovRadius          = [d floatForKey:kFovRadiusKey];
    if ([d objectForKey:kSnapToCenterKey])       _snapToCenter       = [d boolForKey:kSnapToCenterKey];
    if ([d objectForKey:kCenterPullStrengthKey]) _centerPullStrength = [d floatForKey:kCenterPullStrengthKey];
    if ([d objectForKey:kHeadshotModeKey])       _headshotMode       = [d boolForKey:kHeadshotModeKey];
    if ([d objectForKey:kHeadshotSnapRadiusKey]) _headshotSnapRadius = [d floatForKey:kHeadshotSnapRadiusKey];
    _smoothingFactor = _strength * 0.35f;
}

- (void)saveSettings {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.aimassist.settings"];
    [d setBool:_enabled            forKey:kEnabledKey];
    [d setFloat:_strength           forKey:kStrengthKey];
    [d setBool:_fovEnabled         forKey:kFovEnabledKey];
    [d setFloat:_fovRadius          forKey:kFovRadiusKey];
    [d setBool:_snapToCenter       forKey:kSnapToCenterKey];
    [d setFloat:_centerPullStrength forKey:kCenterPullStrengthKey];
    [d setBool:_headshotMode       forKey:kHeadshotModeKey];
    [d setFloat:_headshotSnapRadius forKey:kHeadshotSnapRadiusKey];
    [d synchronize];
    _smoothingFactor = _strength * 0.35f;
}

- (float)distanceFromCenter:(CGPoint)p {
    CGSize s = [UIScreen mainScreen].bounds.size;
    float dx = p.x - s.width  * 0.5f;
    float dy = p.y - s.height * 0.5f;
    return sqrtf(dx * dx + dy * dy);
}

- (CGPoint)snapTowardCenter:(CGPoint)p strength:(float)str {
    CGSize s = [UIScreen mainScreen].bounds.size;
    float cx = s.width * 0.5f, cy = s.height * 0.5f;
    return CGPointMake(p.x + (cx - p.x) * str,
                       p.y + (cy - p.y) * str);
}

// ═══════════════════════════════════════════════════════════════════════════
//  核心滤波算法 — 自然手感 + 可感知辅助
//
//  参数映射（strength=0.6, centerPull=0.5 为例）：
//    EMA factor:   0.21 基础 → FOV 内最高 0.36（64%~79% 移动量通过）
//    中心拉力:     FOV 外 2.5% → FOV 内最高 6% → 头击区 12%
//    硬上限:       平滑 ≤50%，拉力 ≤15%
// ═══════════════════════════════════════════════════════════════════════════
- (CGPoint)processTouchMovement:(CGPoint)raw previousPoint:(CGPoint)prev {
    if (!_enabled || _strength <= 0.0f) return raw;

    CGSize screen = [UIScreen mainScreen].bounds.size;
    float cx = screen.width  * 0.5f;
    float cy = screen.height * 0.5f;
    float dist = sqrtf((raw.x - cx) * (raw.x - cx) + (raw.y - cy) * (raw.y - cy));

    // ── 1. 基础 EMA 平滑 ──
    float factor = _smoothingFactor;

    // ── 2. FOV 内增强平滑 ──
    BOOL inFov = _fovEnabled && (dist < _fovRadius);
    if (inFov) {
        float influence = 1.0f - (dist / _fovRadius);  // 0~1
        factor += influence * 0.15f;                    // 最多 +15%
    }
    factor = fminf(factor, 0.50f);  // 硬上限 50%

    float x = prev.x + (raw.x - prev.x) * (1.0f - factor);
    float y = prev.y + (raw.y - prev.y) * (1.0f - factor);

    // ── 3. 中心拉力 ──
    if (_snapToCenter && _centerPullStrength > 0.0f) {
        float pull;
        if (inFov) {
            float influence = 1.0f - (dist / _fovRadius);
            pull = _centerPullStrength * (0.03f + influence * 0.09f);  // 1.5%~6%
        } else {
            pull = _centerPullStrength * 0.05f;  // FOV 外 2.5%
        }

        // 头击模式：锁定区附近拉力翻倍
        if (_headshotMode && dist < _headshotSnapRadius * 3.0f) {
            pull *= 2.0f;  // 最多 12%
        }

        pull = fminf(pull, 0.15f);  // 硬上限 15%

        x += (cx - x) * pull;
        y += (cy - y) * pull;
    }

    return CGPointMake(x, y);
}

- (void)setStrength:(float)s {
    _strength = s;
    _smoothingFactor = s * 0.35f;
}

@end
