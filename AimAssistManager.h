#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface AimAssistManager : NSObject

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) float strength;           // 0.0 - 1.0  基础平滑强度
@property (nonatomic, assign) float smoothingFactor;    // 0.0 - 0.95 当前平滑系数
@property (nonatomic, assign) BOOL fovEnabled;          // FOV 圈开关
@property (nonatomic, assign) float fovRadius;          // FOV 半径 (pts)
@property (nonatomic, assign) BOOL snapToCenter;        // FOV 内磁吸吸附开关
@property (nonatomic, assign) float centerPullStrength; // 中心拉力强度 0.0 - 1.0

+ (instancetype)sharedManager;
- (void)loadSettings;
- (void)saveSettings;
- (CGPoint)processTouchMovement:(CGPoint)currentPoint previousPoint:(CGPoint)previousPoint;
- (CGPoint)snapTowardCenter:(CGPoint)point strength:(float)pullStrength;
- (float)distanceFromCenter:(CGPoint)point;

@end