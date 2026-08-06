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
        _strength           = 0.95f;          // 95% — 极强平滑
        _smoothingFactor    = 0.81f;          // strength * 0.85
        _fovEnabled         = YES;
        _fovRadius          = 300.0f;         // 300pt FOV
        _snapToCenter       = YES;
        _centerPullStrength = 0.85f;          // 85% 磁吸
        _headshotMode       = YES;
        _headshotSnapRadius = 40.0f;          // 40pt 锁定区
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
    _smoothingFactor = _strength * 0.85f;
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
    _smoothingFactor = _strength * 0.85f;
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
//  核心滤波算法（Unity 优化版）
//
//  ── 在任何情况下都施加 EMA 平滑
//  ── 在任何情况下都施加中心磁吸（FOV 内增强）
//  ── 头击模式：锁定区直接拉到中心，FOV 内额外增强
//  ── 平滑系数 = smoothingFactor + FOV 增强
//  ── 磁吸力度 = centerPullStrength × FOV 影响因子
//  ── FOV 外仍有 10% 基础磁吸，确保准星持续向中心收敛
// ═══════════════════════════════════════════════════════════════════════════
- (CGPoint)processTouchMovement:(CGPoint)raw previousPoint:(CGPoint)prev {
    if (!_enabled || _strength <= 0.0f) return raw;

    CGSize screen = [UIScreen mainScreen].bounds.size;
    float cx = screen.width  * 0.5f;
    float cy = screen.height * 0.5f;
    float dist = sqrtf((raw.x - cx) * (raw.x - cx) + (raw.y - cy) * (raw.y - cy));

    // ── 1. 头击锁定 ──
    if (_headshotMode && dist < _headshotSnapRadius) {
        return CGPointMake(cx, cy);
    }

    // ── 2. EMA 平滑（始终） ──
    float factor = _smoothingFactor;
    float x = prev.x + (raw.x - prev.x) * (1.0f - factor);
    float y = prev.y + (raw.y - prev.y) * (1.0f - factor);

    // ── 3. 基础磁吸（FOV 外 10%，FOV 内增强） ──
    if (_snapToCenter && _centerPullStrength > 0.0f) {
        BOOL inFov = _fovEnabled && (dist < _fovRadius);

        if (inFov) {
            // FOV 内：越靠近中心磁吸越强
            float influence = 1.0f - (dist / _fovRadius);   // 0~1
            float boost = influence * 0.55f * _strength;     // 最大 52%
            if (_headshotMode) boost *= 1.5f;
            float adjFactor = fminf(factor + boost, 0.97f);

            // 重新用增强系数做平滑
            x = prev.x + (raw.x - prev.x) * (1.0f - adjFactor);
            y = prev.y + (raw.y - prev.y) * (1.0f - adjFactor);

            // FOV 内磁吸
            float pull = _centerPullStrength * influence * _strength * 0.65f;
            if (_headshotMode) {
                pull = fminf(pull * 3.0f, 0.95f);
            } else {
                pull = fminf(pull, 0.8f);
            }

            CGPoint s = [self snapTowardCenter:CGPointMake(x, y) strength:pull];
            x = s.x; y = s.y;

            // 头击模式：锁定区附近额外拉
            if (_headshotMode) {
                float d = sqrtf((x - cx) * (x - cx) + (y - cy) * (y - cy));
                if (d < _headshotSnapRadius * 3.0f) {
                    float extra = _centerPullStrength * 0.65f;
                    x += (cx - x) * extra;
                    y += (cy - y) * extra;
                }
            }
        } else {
            // FOV 外：基础磁吸 10%
            float basePull = _centerPullStrength * 0.10f;
            x += (cx - x) * basePull;
            y += (cy - y) * basePull;
        }
    }

    return CGPointMake(x, y);
}

- (void)setStrength:(float)s {
    _strength = s;
    _smoothingFactor = s * 0.85f;
}

@end