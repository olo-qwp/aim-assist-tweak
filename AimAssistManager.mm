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
        _strength           = 0.5f;           // 50% — 自然手感
        _smoothingFactor    = 0.125f;         // strength * 0.25
        _fovEnabled         = YES;
        _fovRadius          = 200.0f;         // 200pt FOV（视觉+微调）
        _snapToCenter       = YES;
        _centerPullStrength = 0.4f;           // 40% → 实际拉力 1.2%
        _headshotMode       = NO;             // 默认关闭，不再强制吸附
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
    _smoothingFactor = _strength * 0.25f;
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
    _smoothingFactor = _strength * 0.25f;
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
//  核心滤波算法 — 自然手感版
//
//  设计原则：
//  1. EMA 平滑系数很低 (0.05~0.25)，大部分移动直接传递，只平滑抖动
//  2. 中心拉力极弱 (1~3%)，仅辅助压枪，不和手指对抗
//  3. 不做强制吸附，玩家始终拥有控制权
//  4. FOV 内略微增强平滑 (+0.05)，FOV 外正常
//  5. 头击模式：仅在锁定区附近增强拉力 (×2)，不吸附到中心
// ═══════════════════════════════════════════════════════════════════════════
- (CGPoint)processTouchMovement:(CGPoint)raw previousPoint:(CGPoint)prev {
    if (!_enabled || _strength <= 0.0f) return raw;

    CGSize screen = [UIScreen mainScreen].bounds.size;
    float cx = screen.width  * 0.5f;
    float cy = screen.height * 0.5f;
    float dist = sqrtf((raw.x - cx) * (raw.x - cx) + (raw.y - cy) * (raw.y - cy));

    // ── 1. 基础 EMA 平滑（始终） ──
    float factor = _smoothingFactor;

    // ── 2. FOV 内增强平滑（微调） ──
    BOOL inFov = _fovEnabled && (dist < _fovRadius);
    if (inFov) {
        float influence = 1.0f - (dist / _fovRadius);
        factor += influence * 0.05f;  // 最多 +5%
    }
    factor = fminf(factor, 0.30f);  // 上限 30%（70% 移动量）

    float x = prev.x + (raw.x - prev.x) * (1.0f - factor);
    float y = prev.y + (raw.y - prev.y) * (1.0f - factor);

    // ── 3. 中心拉力（极弱，仅辅助压枪） ──
    if (_snapToCenter && _centerPullStrength > 0.0f) {
        float pull = _centerPullStrength * 0.03f;  // 基础 1.2%

        if (inFov) {
            // FOV 内：拉力随距离增强
            float influence = 1.0f - (dist / _fovRadius);
            pull = _centerPullStrength * (0.02f + influence * 0.04f);  // 0.8%~2.4%
        }

        // 头击模式：锁定区附近拉力翻倍（不吸附，仅增强）
        if (_headshotMode && dist < _headshotSnapRadius * 3.0f) {
            pull *= 2.0f;  // 最多 ~4.8%
        }

        pull = fminf(pull, 0.05f);  // 硬上限 5%

        x += (cx - x) * pull;
        y += (cy - y) * pull;
    }

    return CGPointMake(x, y);
}

- (void)setStrength:(float)s {
    _strength = s;
    _smoothingFactor = s * 0.25f;
}

@end
