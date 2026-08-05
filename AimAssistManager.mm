#import "AimAssistManager.h"

static NSString *const kEnabledKey  = @"AimAssist_Enabled";
static NSString *const kStrengthKey = @"AimAssist_Strength";

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
        _enabled         = YES;
        _strength        = 0.5f;
        _smoothingFactor = 0.4f;
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
    _smoothingFactor = _strength * 0.8f;
}

- (void)saveSettings {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.aimassist.settings"];
    [defaults setBool:_enabled forKey:kEnabledKey];
    [defaults setFloat:_strength forKey:kStrengthKey];
    [defaults synchronize];
}

- (CGPoint)processTouchMovement:(CGPoint)currentPoint previousPoint:(CGPoint)previousPoint {
    if (!_enabled || _strength <= 0.0f) {
        return currentPoint;
    }

    float factor = _smoothingFactor;
    float x = previousPoint.x + (currentPoint.x - previousPoint.x) * (1.0f - factor);
    float y = previousPoint.y + (currentPoint.y - previousPoint.y) * (1.0f - factor);

    return CGPointMake(x, y);
}

@end