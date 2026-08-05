#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface AimAssistManager : NSObject

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) float strength;        // 0.0 - 1.0
@property (nonatomic, assign) float smoothingFactor; // 0.0 - 0.95

+ (instancetype)sharedManager;
- (void)loadSettings;
- (void)saveSettings;
- (CGPoint)processTouchMovement:(CGPoint)currentPoint previousPoint:(CGPoint)previousPoint;

@end