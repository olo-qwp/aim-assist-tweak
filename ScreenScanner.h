#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "ESPManager.h"

// ═══════════════════════════════════════════════════════════════════════════
//  ScreenScanner — 基于屏幕截图的实时敌人检测
//
//  原理：
//  定期截取游戏画面，通过计算机视觉分析检测屏幕上的敌人。
//  不依赖游戏内存结构，适用于任何游戏。
//
//  检测策略（多策略融合）：
//  1. 颜色检测：检测屏幕中的红色/橙色区域（多数FPS游戏用红色标记敌人）
//  2. 运动检测：对比连续帧，检测移动的物体
//  3. 边缘检测：检测人形轮廓
//
//  性能优化：
//  - 降采样：将截图缩小到 1/4 分辨率进行分析
//  - 间隔扫描：每 100ms 扫描一次（10fps）
//  - 区域限制：优先扫描屏幕中心区域（准心附近）
// ═══════════════════════════════════════════════════════════════════════════

@interface ScreenScanner : NSObject

+ (instancetype)sharedScanner;

/// 开始扫描
- (void)startScanning;

/// 停止扫描
- (void)stopScanning;

/// 是否正在扫描
@property (nonatomic, readonly) BOOL isScanning;

/// 敌人检测灵敏度 (0.1 ~ 1.0，越高检测越敏感)
@property (nonatomic, assign) float sensitivity;

/// 是否启用运动检测
@property (nonatomic, assign) BOOL motionDetectionEnabled;

/// 校准敌人颜色（用户对准敌人校准后提取的主色，任何引擎通用）
@property (nonatomic, readonly) NSArray<NSDictionary *> *calibColors;

/// 校准：截取当前屏幕中心区域，提取敌人主色（准心对准敌人时按下）
- (void)calibrateWithScreen;

/// 清除校准色
- (void)clearCalibration;

@end