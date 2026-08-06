#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class ESPPlayerData;

@interface AimAssistManager : NSObject

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) float strength;           // 0.0 - 1.0  自瞄拉力强度
@property (nonatomic, assign) BOOL fovEnabled;          // FOV 圈开关
@property (nonatomic, assign) float fovRadius;          // FOV 半径 (pts)

+ (instancetype)sharedManager;
- (void)loadSettings;
- (void)saveSettings;

// 基于ESP头部坐标的自瞄偏移量
// 返回需要将触摸坐标偏移的量，实现拉向最近敌人头部
- (CGPoint)aimOffsetForTouch:(CGPoint)touch
                   fromPoint:(CGPoint)prevTouch
                  screenSize:(CGSize)screenSize;

@end