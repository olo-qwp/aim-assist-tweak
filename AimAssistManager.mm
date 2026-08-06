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
    static AimAssistManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AimAssistManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 默认值：更激进的自瞄效果
        _enabled            = YES;
        _strength           = 0.85f;          // 85% 强度
        _smoothingFactor    = 0.72f;           // strength * 0.85
        _fovEnabled         = YES;
        _fovRadius          = 200.0f;          // 200pt FOV
        _snapToCenter       = YES;
        _centerPullStrength = 0.65f;           // 65% 磁吸
        _headshotMode       = YES;
        _headshotSnapRadius = 30.0f;           // 30pt 锁定区
    }
    return self;
}

- (void)loadSettings {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.aimassist.settings"];
    if ([defaults objectForKey:kEnabledKey])            _enabled            = [defaults boolForKey:kEnabledKey];
    if ([defaults objectForKey:kStrengthKey])           _strength           = [defaults floatForKey:kStrengthKey];
    if ([defaults objectForKey:kFovEnabledKey])         _fovEnabled         = [defaults boolForKey:kFovEnabledKey];
    if ([defaults objectForKey:kFovRadiusKey])          _fovRadius          = [defaults floatForKey:kFovRadiusKey];
    if ([defaults objectForKey:kSnapToCenterKey])       _snapToCenter       = [defaults boolForKey:kSnapToCenterKey];
    if ([defaults objectForKey:kCenterPullStrengthKey]) _centerPullStrength = [defaults floatForKey:kCenterPullStrengthKey];
    if ([defaults objectForKey:kHeadshotModeKey])       _headshotMode       = [defaults boolForKey:kHeadshotModeKey];
    if ([defaults objectForKey:kHeadshotSnapRadiusKey]) _headshotSnapRadius = [defaults floatForKey:kHeadshotSnapRadiusKey];
    _smoothingFactor = _strength * 0.85f;
}

- (void)saveSettings {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.aimassist.settings"];
    [defaults setBool:_enabled            forKey:kEnabledKey];
    [defaults setFloat:_strength           forKey:kStrengthKey];
    [defaults setBool:_fovEnabled         forKey:kFovEnabledKey];
    [defaults setFloat:_fovRadius          forKey:kFovRadiusKey];
    [defaults setBool:_snapToCenter       forKey:kSnapToCenterKey];
    [defaults setFloat:_centerPullStrength forKey:kCenterPullStrengthKey];
    [defaults setBool:_headshotMode       forKey:kHeadshotModeKey];
    [defaults setFloat:_headshotSnapRadius forKey:kHeadshotSnapRadiusKey];
    [defaults synchronize];
    _smoothingFactor = _strength * 0.85f;
}

- (float)distanceFromCenter:(CGPoint)point {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat cx = screen.width * 0.5f;
    CGFloat cy = screen.height * 0.5f;
    CGFloat dx = point.x - cx;
    CGFloat dy = point.y - cy;
    return sqrtf(dx * dx + dy * dy);
}

- (CGPoint)snapTowardCenter:(CGPoint)point strength:(float)pullStrength {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat cx = screen.width * 0.5f;
    CGFloat cy = screen.height * 0.5f;
    CGFloat dx = cx - point.x;
    CGFloat dy = cy - point.y;
    return CGPointMake(point.x + dx * pullStrength,
                       point.y + dy * pullStrength);
}

// ═══════════════════════════════════════════════════════════════════════════
//  核心滤波逻辑
//  ── 基础 EMA 平滑
//  ── FOV 内增强（越靠近中心越强）
//  ── 磁吸吸附（将触摸拉向屏幕中心）
//  ── 头击锁定（进入小半径区域直接拉到中心）
// ═══════════════════════════════════════════════════════════════════════════
- (CGPoint)processTouchMovement:(CGPoint)currentPoint previousPoint:(CGPoint)previousPoint {
    if (!_enabled || _strength <= 0.0f) {
        return currentPoint;
    }

    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat cx = screen.width * 0.5f;
    CGFloat cy = screen.height * 0.5f;
    CGFloat dist = [self distanceFromCenter:currentPoint];

    // ──────────────────────────────────────────────────────────────────────
    //  1. 头击模式：锁定区 → 直接拉到屏幕中心
    // ──────────────────────────────────────────────────────────────────────
    if (_headshotMode && dist < _headshotSnapRadius) {
        return CGPointMake(cx, cy);
    }

    // ──────────────────────────────────────────────────────────────────────
    //  2. 基础 EMA 平滑
    // ──────────────────────────────────────────────────────────────────────
    float factor = _smoothingFactor;
    float x = previousPoint.x + (currentPoint.x - previousPoint.x) * (1.0f - factor);
    float y = previousPoint.y + (currentPoint.y - previousPoint.y) * (1.0f - factor);

    // ──────────────────────────────────────────────────────────────────────
    //  3. FOV 增强
    // ──────────────────────────────────────────────────────────────────────
    BOOL insideFov = _fovEnabled && (dist < _fovRadius);

    if (insideFov) {
        // FOV 内：越靠近中心，平滑系数越大（移动越慢）
        float fovInfluence = 1.0f - (dist / _fovRadius);         // 0~1
        float boost = fovInfluence * 0.45f * _strength;          // 最大 38%
        if (_headshotMode) {
            boost *= 1.6f;  // 头击模式额外增强
        }
        float adjFactor = fminf(factor + boost, 0.95f);

        x = previousPoint.x + (currentPoint.x - previousPoint.x) * (1.0f - adjFactor);
        y = previousPoint.y + (currentPoint.y - previousPoint.y) * (1.0f - adjFactor);

        // ────────────────────────────────────────────────────────────────
        //  4. 磁吸吸附（仅 FOV 内）
        // ────────────────────────────────────────────────────────────────
        if (_snapToCenter && _centerPullStrength > 0.0f) {
            // 磁吸力 = 基础强度 × FOV 影响因子 × 总强度 × 缩放
            float effectivePull = _centerPullStrength * fovInfluence * _strength * 0.55f;

            if (_headshotMode) {
                // 头击模式：磁吸力更强，上限 0.95
                effectivePull = fminf(effectivePull * 3.0f, 0.95f);
            } else {
                effectivePull = fminf(effectivePull, 0.7f);
            }

            CGPoint snapped = [self snapTowardCenter:CGPointMake(x, y)
                                            strength:effectivePull];
            x = snapped.x;
            y = snapped.y;

            // ────────────────────────────────────────────────────────────
            //  5. 头击模式：FOV 边界往内拉（把触摸拉进锁定区）
            // ────────────────────────────────────────────────────────────
            if (_headshotMode) {
                float postDist = sqrtf((x - cx) * (x - cx) + (y - cy) * (y - cy));
                if (postDist < _headshotSnapRadius * 2.0f) {
                    // 距离锁定区 2x 半径内 → 额外拉向中心
                    float extraPull = _centerPullStrength * 0.7f;
                    x += (cx - x) * extraPull;
                    y += (cy - y) * extraPull;
                }
            }
        }
    }

    return CGPointMake(x, y);
}

// ── strength 的 setter：同步更新 smoothingFactor ──
- (void)setStrength:(float)strength {
    _strength = strength;
    _smoothingFactor = strength * 0.85f;
}

@end