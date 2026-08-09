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

// ═══════════════════════════════════════════════════════════════════════════
//  模型选择 — 用准心瞄准游戏内模型并锁定跟踪（CAMSHIFT 风格）
//
//  原理：
//  1. selectModelWithScreen：截取准心周围区域 → 构建目标颜色直方图模型
//  2. 每帧直方图反投影（每像素查表得到"属于目标"的概率）+ MeanShift
//     迭代收敛到质心 → 跟踪目标在屏幕上的位置
//  3. 对目标缩放/旋转鲁棒（颜色分布不变），3D 游戏走近走远都能跟
//  4. 置信度过低/连续丢失 → 自动放弃锁定，回退常规检测
// ═══════════════════════════════════════════════════════════════════════════

/// 是否已选中模型
@property (nonatomic, readonly) BOOL hasSelectedModel;

/// 选中模型当前屏幕位置（跟踪成功时为有效值）
@property (nonatomic, readonly) CGPoint selectedModelPos;

/// 选中模型框尺寸（用于 ESP 绘制）
@property (nonatomic, readonly) CGSize selectedModelSize;

/// 选中模型置信度（0~1，>0.5 视为可靠）
@property (nonatomic, readonly) float selectedConfidence;

/// 用准心对准模型后调用：截取屏幕中心区域建模
- (void)selectModelWithScreen;

/// 取消选中模型
- (void)clearSelectedModel;

@end