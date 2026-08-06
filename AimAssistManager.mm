#import "AimAssistManager.h"

static NSString *const kEnabledKey          = @"AimAssist_Enabled";
static NSString *const kStrengthKey         = @"AimAssist_Strength";
static NSString *const kFovEnabledKey       = @"AimAssist_FovEnabled";
static NSString *const kFovRadiusKey        = @"AimAssist_FovRadius";
static NSString *const kSnapToCenterKey     = @"AimAssist_SnapToCenter";
static NSString *const kCenterPullStrengthKey = @"AimAssist_CenterPullStrength";

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
    [defaults synchronize];
}

- (float)distanceFromCenter:(CGPoint)point {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat cx = screen.width * 0.5f;
    CGFloat cy = screen.height * 0.5f;
    CGFloat dx = point.x - cx;
    CGFloat dy = point.y - cy;
    return sqrtf(dx * dx + dy * dy);
}

/// 将触摸点向屏幕中心磁吸拉拽
- (CGPoint)snapTowardCenter:(CGPoint)point strength:(float)pullStrength {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat cx = screen.width * 0.5f;
    CGFloat cy = screen.height * 0.5f;

    CGFloat dx = cx - point.x;
    CGFloat dy = cy - point.y;

    // pullStrength 0~1，控制拉拽比例
    CGFloat pulledX = point.x + dx * pullStrength;
    CGFloat pulledY = point.y + dy * pullStrength;

    return CGPointMake(pulledX, pulledY);
}

- (CGPoint)processTouchMovement:(CGPoint)currentPoint previousPoint:(CGPoint)previousPoint {
    if (!_enabled || _strength <= 0.0f) {
        return currentPoint;
    }

    // ── 1. 基础 EMA 平滑 ──
    float factor = _smoothingFactor;
    float x = previousPoint.x + (currentPoint.x - previousPoint.x) * (1.0f - factor);
    float y = previousPoint.y + (currentPoint.y - previousPoint.y) * (1.0f - factor);

    // ── 2. FOV 增强 ──
    float dist = [self distanceFromCenter:currentPoint];
    BOOL insideFov = _fovEnabled && (dist < _fovRadius);

    if (insideFov) {
        // FOV 内增强平滑（越靠近中心越平滑）
        float fovInfluence = 1.0f - (dist / _fovRadius);
        float boost = fovInfluence * 0.35f * _strength;
        float adjFactor = fminf(factor + boost, 0.95f);

        x = previousPoint.x + (currentPoint.x - previousPoint.x) * (1.0f - adjFactor);
        y = previousPoint.y + (currentPoint.y - previousPoint.y) * (1.0f - adjFactor);

        // ── 3. 磁吸吸附：将平滑后的点向屏幕中心拉拽 ──
        if (_snapToCenter && _centerPullStrength > 0.0f) {
            // FOV 内越靠近中心拉力越强
            float fovFactor = 1.0f - (dist / _fovRadius);
            float effectivePull = _centerPullStrength * fovFactor * _strength * 0.5f;
            effectivePull = fminf(effectivePull, 0.6f);

            CGPoint snapped = [self snapTowardCenter:CGPointMake(x, y) strength:effectivePull];
            x = snapped.x;
            y = snapped.y;
        }
    }

    return CGPointMake(x, y);
}

@end