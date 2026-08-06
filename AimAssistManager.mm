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
        _strength           = 0.6f;           // 60% 平滑
        _smoothingFactor    = 0.21f;          // strength * 0.35
        _fovEnabled         = YES;
        _fovRadius          = 200.0f;
        _snapToCenter       = YES;
        _centerPullStrength = 0.5f;           // 50% 磁吸
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
//  核心滤波算法
//
//  1. EMA 平滑：减少触摸抖动，factor 越高越平滑
//     factor = strength * 0.35 + FOV增强(最多+0.15)，上限 0.50
//     → 至少 50% 的移动量直接通过，手感自然
//
//  2. 中心拉力：将准星拉向屏幕中心
//     FOV 外：centerPull * 0.05（2.5%@50%设置）
//     FOV 内：centerPull * (0.05 + influence * 0.15)（5%~12.5%@50%设置）
//     头击区：×2（最高 25%）
//     硬上限：25%
//
//  3. influence = 1 - dist/fovRadius（越靠近中心越强）
// ═══════════════════════════════════════════════════════════════════════════
- (CGPoint)processTouchMovement:(CGPoint)raw previousPoint:(CGPoint)prev {
    if (!_enabled || _strength <= 0.0f) return raw;

    CGSize screen = [UIScreen mainScreen].bounds.size;
    float cx = screen.width  * 0.5f;
    float cy = screen.height * 0.5f;
    float dist = sqrtf((raw.x - cx) * (raw.x - cx) + (raw.y - cy) * (raw.y - cy));

    // ── 1. EMA 平滑 ──
    float factor = _smoothingFactor;

    BOOL inFov = _fovEnabled && (dist < _fovRadius);
    if (inFov) {
        float influence = 1.0f - (dist / _fovRadius);
        factor += influence * 0.15f;
    }
    factor = fminf(factor, 0.50f);

    float x = prev.x + (raw.x - prev.x) * (1.0f - factor);
    float y = prev.y + (raw.y - prev.y) * (1.0f - factor);

    // ── 2. 中心拉力 ──
    if (_snapToCenter && _centerPullStrength > 0.0f) {
        float pull;

        if (inFov) {
            float influence = 1.0f - (dist / _fovRadius);
            pull = _centerPullStrength * (0.05f + influence * 0.15f);
        } else {
            pull = _centerPullStrength * 0.05f;
        }

        if (_headshotMode && dist < _headshotSnapRadius * 3.0f) {
            pull *= 2.0f;
        }

        pull = fminf(pull, 0.25f);

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
