#import <Foundation/Foundation.h>

// ═══════════════════════════════════════════════════════════════════════════
//  EnemyMemoryReader — Unity IL2CPP 内存模型敌人检测
//
//  通过 il2cpp 导出 API 直接读取游戏对象层：
//    GameObject.FindGameObjectsWithTag("Enemy"/"Zombie"/...)
//  → Transform.get_position 世界坐标 → Camera 投影矩阵 → 屏幕坐标
//
//  命中（有内存敌人数据）→ 直接更新 ESP（优先于屏幕识别）
//  未命中 / 非 Unity 游戏 → 静默返回，屏幕识别继续工作
//
//  容错设计：所有 il2cpp 函数指针 dlsym 探测，任一缺失即禁用；
//  每次 tick 任一环节失败返回 nil，不崩溃。
//  (ponytail: 已知天花板 —— 若游戏内方法抛托管异常，IL2CPP 无托管栈
//   时会终止进程；此处仅调用引擎标准无异常路径 API，接受该风险)
// ═══════════════════════════════════════════════════════════════════════════

@interface EnemyMemoryReader : NSObject

+ (instancetype)sharedReader;

/// 是否成功探测到 Unity IL2CPP
- (BOOL)isUnityAvailable;

/// 是否成功探测到 Cocos2d-x（无偏移内存路径）
- (BOOL)cocosAvailable;

/// Cocos 内存跟踪：在场景树中找离锚点最近的合理节点 → 屏幕坐标
- (BOOL)trackCocosModelNear:(CGPoint)anchor outPos:(CGPoint *)outPos outSize:(float *)outSize;

/// 后台队列 10Hz 轮询内存敌人数据（探测失败时自动静默）
- (void)start;

- (void)stop;

@end
