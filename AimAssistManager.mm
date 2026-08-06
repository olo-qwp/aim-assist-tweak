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
        _enabled            = YES;
        _strength           = 0.5f;
        _smoothingFactor    = 0.4f;
        _fovEnabled         = YES;
        _fovRadius          = 150.0f;
        _snapToCenter       = YES;
        _centerPullStrength = 0.4f;
        _headshotMode       = NO;
        _headshotSnapRadius = 30.0f;
    }
    return self;
}

- (void)loadSettings {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.aimassist.settings"];
    if ([defaults objectForKey:kEnabledKey]) {
        _enabled = [defaults boolForKey:kEnabledKey];
    }
    if ([defaults objectForKey:kStrengthKey]) {
        _strength = [defaults floatForKey:kStrengthKey];
    }
    if ([defaults objectForKey:kFovEnabledKey]) {
        _fovEnabled = [defaults boolForKey:kFovEnabledKey];
    }
    if ([defaults objectForKey:kFovRadiusKey]) {
        _fovRadius = [defaults floatForKey:kFovRadiusKey];
    }
    if ([defaults objectForKey:kSnapToCenterKey]) {
        _snapToCenter = [defaults boolForKey:kSnapToCenterKey];
    }
    if ([defaults objectForKey:kCenterPullStrengthKey]) {
        _centerPullStrength = [defaults floatForKey:kCenterPullStrengthKey];
    }
    if ([defaults objectForKey:kHeadshotModeKey]) {
        _headshotMode = [defaults boolForKey:kHeadshotModeKey];
    }
    if ([defaults objectForKey:kHeadshotSnapRadiusKey]) {
        _headshotSnapRadius = [defaults floatForKey:kHeadshotSnapRadiusKey];
    }
    _smoothingFactor = _strength * 0.88f;
}

- (void)saveSettings {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.aimassist.settings"];
    [defaults setBool:_enabled forKey:kEnabledKey];
    [defaults setFloat:_strength forKey:kStrengthKey];
    [defaults setBool:_fovEnabled forKey:kFovEnabledKey];
    [defaults setFloat:_fovRadius forKey:kFovRadiusKey];
    [defaults setBool:_snapToCenter forKey:kSnapToCenterKey];
    [defaults setFloat:_centerPullStrength forKey:kCenterPullStrengthKey];
    [defaults setBool:_headshotMode forKey:kHeadshotModeKey];
    [defaults setFloat:_headshotSnapRadius forKey:kHeadshotSnapRadiusKey];
    [defaults synchronize];
    // 更新平滑系数
    _smoothingFactor = _strength * 0.88f;
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

    CGFloat pulledX = point.x + dx * pullStrength;
    CGFloat pulledY = point.y + dy * pullStrength;

    return CGPointMake(pulledX, pulledY);
}

- (CGPoint)processTouchMovement:(CGPoint)currentPoint previousPoint:(CGPoint)previousPoint {
    if (!_enabled || _strength <= 0.0f) {
        return currentPoint;
    }

    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat cx = screen.width * 0.5f;
    CGFloat cy = screen.height * 0.5f;
    CGFloat dist = [self distanceFromCenter:currentPoint];

    // ═══════════════════════════════════════════════════════════════
    //  头击模式：锁定区 → 直接拉到中心
    // ═══════════════════════════════════════════════════════════════
    if (_headshotMode && dist < _headshotSnapRadius) {
        // 进入锁定区 → 直接吸附到中心（模拟瞄头）
        return CGPointMake(cx, cy);
    }

    // ═══════════════════════════════════════════════════════════════
    //  基础 EMA 平滑
    // ═══════════════════════════════════════════════════════════════
    float factor = _smoothingFactor;
    float x = previousPoint.x + (currentPoint.x - previousPoint.x) * (1.0f - factor);
    float y = previousPoint.y + (currentPoint.y - previousPoint.y) * (1.0f - factor);

    // ═══════════════════════════════════════════════════════════════
    //  FOV 增强
    // ═══════════════════════════════════════════════════════════════
    BOOL insideFov = _fovEnabled && (dist < _fovRadius);

    if (insideFov) {
        // FOV 内增强平滑
        float fovInfluence = 1.0f - (dist / _fovRadius);
        float boost = fovInfluence * 0.35f * _strength;
        if (_headshotMode) {
            boost *= 1.5f;  // 头击模式增强平滑效果
        }
        float adjFactor = fminf(factor + boost, 0.95f);

        x = previousPoint.x + (currentPoint.x - previousPoint.x) * (1.0f - adjFactor);
        y = previousPoint.y + (currentPoint.y - previousPoint.y) * (1.0f - adjFactor);

        // ══════════════════════════════════════════════════════════
        //  磁吸吸附
        // ══════════════════════════════════════════════════════════
        if (_snapToCenter && _centerPullStrength > 0.0f) {
            float effectivePull = _centerPullStrength * fovInfluence * _strength * 0.5f;

            if (_headshotMode) {
                // 头击模式：拉力翻倍，上限提高到 0.9
                effectivePull = fminf(effectivePull * 2.5f, 0.9f);
            } else {
                effectivePull = fminf(effectivePull, 0.6f);
            }

            CGPoint snapped = [self snapTowardCenter:CGPointMake(x, y) strength:effectivePull];
            x = snapped.x;
            y = snapped.y;
        }

        // ══════════════════════════════════════════════════════════
        //  头击模式：FOV 边界的磁吸引力（把触摸拉进锁定区）
        // ══════════════════════════════════════════════════════════
        if (_headshotMode && _snapToCenter) {
            float postSnapDist = sqrtf((x-cx)*(x-cx) + (y-cy)*(y-cy));
            if (postSnapDist < _headshotSnapRadius * 1.5f) {
                // 距离锁定区边缘 1.5x 内 → 额外拉向中心
                float extraPull = _centerPullStrength * 0.6f;
                x += (cx - x) * extraPull;
                y += (cy - y) * extraPull;
            }
        }
    }

    return CGPointMake(x, y);
}

@end