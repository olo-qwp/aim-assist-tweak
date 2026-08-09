#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

// ═══════════════════════════════════════════════════════════════════════════
//  ESP 数据结构
//
//  用于在屏幕上绘制玩家骨骼/方框/血条等信息
//  数据由游戏特定的内存读取代码填充，绘制由 NativeOverlay 自动完成
// ═══════════════════════════════════════════════════════════════════════════

// 骨骼点定义（关键骨骼位置）
typedef NS_ENUM(NSInteger, ESPBoneType) {
    ESPBoneHead     = 0,
    ESPBoneNeck     = 1,
    ESPBoneChest    = 2,
    ESPBonePelvis   = 3,
    ESPBoneLUpperArm = 4,
    ESPBoneLForearm = 5,
    ESPBoneLHand    = 6,
    ESPBoneRUpperArm = 7,
    ESPBoneRForearm = 8,
    ESPBoneRHand    = 9,
    ESPBoneLThigh   = 10,
    ESPBoneLShin    = 11,
    ESPBoneLFoot    = 12,
    ESPBoneRThigh   = 13,
    ESPBoneRShin    = 14,
    ESPBoneRFoot    = 15,
    ESPBoneCount    = 16
};

// 骨骼连接线（用于绘制骨架）
// 每对索引表示一条骨骼线
static const int ESPBoneConnections[] = {
    ESPBoneHead,  ESPBoneNeck,
    ESPBoneNeck,  ESPBoneChest,
    ESPBoneChest, ESPBonePelvis,
    ESPBoneNeck,  ESPBoneLUpperArm,
    ESPBoneLUpperArm, ESPBoneLForearm,
    ESPBoneLForearm,  ESPBoneLHand,
    ESPBoneNeck,  ESPBoneRUpperArm,
    ESPBoneRUpperArm, ESPBoneRForearm,
    ESPBoneRForearm,  ESPBoneRHand,
    ESPBonePelvis, ESPBoneLThigh,
    ESPBoneLThigh, ESPBoneLShin,
    ESPBoneLShin,  ESPBoneLFoot,
    ESPBonePelvis, ESPBoneRThigh,
    ESPBoneRThigh, ESPBoneRShin,
    ESPBoneRShin,  ESPBoneRFoot,
    -1, -1 // 终止标记
};

// 单个玩家 ESP 数据（屏幕坐标）
@interface ESPPlayerData : NSObject {
    @public
    CGPoint bonePositions[ESPBoneCount]; // 骨骼屏幕坐标（C数组，不能用作ObjC属性）
    int stableCount;                     // 屏幕识别多帧确认计数（内存模型数据不使用）
}
@property (nonatomic, assign) BOOL           isValid;       // 数据是否有效
@property (nonatomic, assign) CGPoint        screenPos;     // 玩家在屏幕上的位置
@property (nonatomic, assign) CGFloat        distance;      // 距离（用于排序/颜色）
@property (nonatomic, assign) CGFloat        health;        // 血量 0.0-1.0
@property (nonatomic, strong) NSString       *name;         // 玩家名称
@property (nonatomic, assign) BOOL           hasBones;      // 是否有骨骼数据
@property (nonatomic, assign) CGRect         boxRect;       // 玩家方框
@property (nonatomic, assign) BOOL           isEnemy;       // 是否是敌人
@end

// ESP 管理器
// 负责存储和提供 ESP 数据，供 NativeOverlay 绘制
@interface ESPManager : NSObject

+ (instancetype)sharedManager;

// ── 数据接口 ──
// 游戏特定的内存读取代码调用此方法提交玩家数据
- (void)updatePlayers:(NSArray<ESPPlayerData *> *)players;

// 获取当前所有玩家数据（供绘制使用）
- (NSArray<ESPPlayerData *> *)currentPlayers;

// ── 设置 ──
@property (nonatomic, assign) BOOL espEnabled;        // ESP 开关
@property (nonatomic, assign) BOOL showSkeleton;      // 显示骨骼
@property (nonatomic, assign) BOOL showBox;           // 显示方框
@property (nonatomic, assign) BOOL showHealth;        // 显示血条
@property (nonatomic, assign) BOOL showName;          // 显示名字
@property (nonatomic, assign) BOOL showCrosshair;     // 显示准心
@property (nonatomic, assign) BOOL showFOV;           // 显示 FOV 圈
@property (nonatomic, assign) float fovRadius;        // FOV 半径

// ── 数据源协调 ──
// 内存模型检测有有效数据时为 YES → ScreenScanner 让位，避免覆盖精确数据
@property (nonatomic, assign) BOOL memoryActive;
// 当前数据源说明（"内存模型" / "屏幕识别"），供 UI 显示
@property (nonatomic, strong) NSString *dataSource;

@end