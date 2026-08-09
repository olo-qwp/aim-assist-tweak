#import "ScreenScanner.h"
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>

// ═══════════════════════════════════════════════════════════════════════════
//  ScreenScanner 实现
//
//  核心算法：
//  1. 截取当前屏幕（降采样到 1/4 提升性能）
//  2. 遍历像素，检测符合敌人颜色特征的像素
//     - 红色系：R > 150, G < 100, B < 100（血条/敌人轮廓/伤害标记）
//     - 橙色系：R > 200, G > 100, G < 180, B < 100（敌人标记）
//     - 品红/粉色系：R > 150, B > 150, G < 100（部分游戏的敌人高亮）
//  3. 将检测到的像素聚类为实体
//  4. 过滤过小的噪点（< 20像素）和过大的区域（UI元素）
//  5. 计算实体的边界框和中心位置
//  6. 生成ESP数据并更新ESPManager
// ═══════════════════════════════════════════════════════════════════════════

@interface ScreenScanner () {
    NSTimer *_scanTimer;
    BOOL _isScanning;
    BOOL _busy;                  // 上一帧分析未完成则跳过本帧（防堆积）
    NSInteger _frameCount;

    // 像素分析专用串行队列（重活全在后台，主线程只做低分辨率截图）
    dispatch_queue_t _scanQueue;

    // 运动检测用的上一帧（仅后台队列访问）
    UInt8 *_prevFrameData;
    size_t _prevFrameSize;
}
@end

@implementation ScreenScanner

+ (instancetype)sharedScanner {
    static ScreenScanner *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ScreenScanner alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sensitivity = 0.5f;
        _motionDetectionEnabled = YES;
        _frameCount = 0;
        _scanQueue = dispatch_queue_create("com.aimassist.scan", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isScanning { return _isScanning; }

// ═══════════════════════════════════════════════════════════════════════════
//  开始/停止扫描
// ═══════════════════════════════════════════════════════════════════════════

- (void)startScanning {
    if (_isScanning) return;
    _isScanning = YES;
    _frameCount = 0;

    // 每 100ms 扫描一次 (10fps)
    _scanTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                  target:self
                                                selector:@selector(performScan)
                                                userInfo:nil
                                                 repeats:YES];
    // 立即执行一次
    [self performScan];
}

- (void)stopScanning {
    _isScanning = NO;
    [_scanTimer invalidate];
    _scanTimer = nil;
    // 排空后台队列再释放上一帧（避免与进行中的分析竞争）
    dispatch_sync(_scanQueue, ^{
        if (_prevFrameData) {
            free(_prevFrameData);
            _prevFrameData = NULL;
            _prevFrameSize = 0;
        }
    });
}

// ═══════════════════════════════════════════════════════════════════════════
//  主扫描逻辑 — 主线程只做低分辨率截图，像素分析全部在后台队列
//  (A11 60fps: 主线程每帧开销 ~2-4ms 截图渲染，重循环不占主线程)
// ═══════════════════════════════════════════════════════════════════════════

- (void)performScan {
    @autoreleasepool {
        if (_busy || !_isScanning) return;
        _busy = YES;
        _frameCount++;

        // 直接以 1/4 线性分辨率截屏（=1/16 像素量，省去全分辨率+降采样两趟）
        UIImage *screenshot = [self captureScreen];
        if (!screenshot) { _busy = NO; return; }
        CGSize origSize = [UIScreen mainScreen].bounds.size;

        dispatch_async(_scanQueue, ^{
            @autoreleasepool {
                // 分析图像，检测敌人（颜色/运动/聚类，全在后台）
                NSArray<ESPPlayerData *> *entities =
                    [self detectEnemiesInImage:screenshot originalSize:origSize];
                BOOL stillScanning = _isScanning;

                dispatch_async(dispatch_get_main_queue(), ^{
                    _busy = NO;
                    if (!stillScanning) return;

                    // 更新 ESP 数据
                    if (entities.count > 0) {
                        [[ESPManager sharedManager] updatePlayers:entities];
                    } else {
                        // 连续多帧无数据后清空
                        static int emptyFrames = 0;
                        emptyFrames++;
                        if (emptyFrames > 5) {
                            [[ESPManager sharedManager] updatePlayers:@[]];
                            emptyFrames = 0;
                        }
                    }
                });
            }
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  截取当前屏幕
// ═══════════════════════════════════════════════════════════════════════════

- (UIImage *)captureScreen {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in ws.windows) {
                        if (w.isKeyWindow) { keyWindow = w; break; }
                    }
                }
            }
        }
        if (!keyWindow) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    keyWindow = ((UIWindowScene *)scene).windows.firstObject;
                    break;
                }
            }
        }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;
    if (!keyWindow) return nil;

    CGRect bounds = keyWindow.bounds;
    // 直接以 1/4 线性分辨率渲染（=1/16 像素量），跳过全分辨率截屏再降采样
    CGFloat capScale = [UIScreen mainScreen].scale * 0.25f;
    UIGraphicsBeginImageContextWithOptions(bounds.size, NO, capScale);
    [keyWindow drawViewHierarchyInRect:bounds afterScreenUpdates:NO];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

// ═══════════════════════════════════════════════════════════════════════════
//  核心检测算法 — 在图像中检测敌人
//
//  使用多策略融合：
//  1. 颜色检测：查找红色/橙色/品红色像素集群
//  2. 运动检测：与上一帧对比，查找变化区域
//  3. 聚类：将相邻的检测像素合并为实体
// ═══════════════════════════════════════════════════════════════════════════

- (NSArray<ESPPlayerData *> *)detectEnemiesInImage:(UIImage *)image
                                      originalSize:(CGSize)origSize {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return @[];

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    size_t bytesPerPixel = 4;
    size_t bytesPerRow = width * bytesPerPixel;
    size_t bitsPerComponent = 8;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSMutableData *pixelData = [NSMutableData dataWithLength:bytesPerRow * height];
    CGContextRef context = CGBitmapContextCreate(pixelData.mutableBytes,
                                                  width, height,
                                                  bitsPerComponent, bytesPerRow,
                                                  colorSpace,
                                                  kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) return @[];

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);

    UInt8 *pixels = (UInt8 *)pixelData.mutableBytes;

    // ── 检测标记图 ──
    // 每个像素标记为：0=背景, 1=颜色匹配, 2=运动匹配
    UInt8 *detectMap = (UInt8 *)calloc(width * height, sizeof(UInt8));
    if (!detectMap) return @[];

    // ── 颜色检测 ──
    int colorThreshold = (int)(150.0f + (1.0f - _sensitivity) * 50.0f); // 灵敏度越高，阈值越低

    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            size_t idx = (y * width + x) * 4;
            UInt8 r = pixels[idx];
            UInt8 g = pixels[idx + 1];
            UInt8 b = pixels[idx + 2];

            // 红色系检测（敌人血条/轮廓/伤害标记）
            if (r > colorThreshold && g < colorThreshold * 0.7f && b < colorThreshold * 0.7f) {
                detectMap[y * width + x] = 1;
                continue;
            }

            // 橙色系检测（敌人高亮标记）
            if (r > 200 && g > 100 && g < 180 && b < 100) {
                detectMap[y * width + x] = 1;
                continue;
            }

            // 品红/粉色系（部分游戏的敌人标记）
            if (r > 150 && b > 150 && g < 100) {
                detectMap[y * width + x] = 1;
                continue;
            }
        }
    }

    // ── 运动检测 ──
    if (_motionDetectionEnabled && _prevFrameData && _prevFrameSize == bytesPerRow * height) {
        int motionThreshold = (int)(30.0f + (1.0f - _sensitivity) * 40.0f);

        for (size_t y = 0; y < height; y++) {
            for (size_t x = 0; x < width; x++) {
                size_t idx = (y * width + x) * 4;
                int dr = abs((int)pixels[idx] - (int)_prevFrameData[idx]);
                int dg = abs((int)pixels[idx + 1] - (int)_prevFrameData[idx + 1]);
                int db = abs((int)pixels[idx + 2] - (int)_prevFrameData[idx + 2]);

                if (dr + dg + db > motionThreshold * 3) {
                    // 运动检测到的像素也标记（但不覆盖颜色检测）
                    if (detectMap[y * width + x] == 0) {
                        detectMap[y * width + x] = 2;
                    }
                }
            }
        }
    }

    // 保存当前帧用于下次运动检测
    if (_prevFrameData == NULL || _prevFrameSize != bytesPerRow * height) {
        if (_prevFrameData) free(_prevFrameData);
        _prevFrameSize = bytesPerRow * height;
        _prevFrameData = (UInt8 *)malloc(_prevFrameSize);
    }
    if (_prevFrameData) memcpy(_prevFrameData, pixels, _prevFrameSize);

    // ── 聚类：将相邻的检测像素合并为实体 ──
    NSMutableArray<ESPPlayerData *> *results = [NSMutableArray array];

    // 使用连通区域标记算法
    int *labels = (int *)calloc(width * height, sizeof(int));
    if (!labels) { free(detectMap); return @[]; }

    int currentLabel = 1;
    // 队列用于 BFS
    size_t queueCapacity = width * height / 4;
    size_t *queueX = (size_t *)malloc(queueCapacity * sizeof(size_t));
    size_t *queueY = (size_t *)malloc(queueCapacity * sizeof(size_t));

    int minPixels = (int)(20.0f * _sensitivity + 10.0f); // 最小像素数
    int maxPixels = (int)(width * height * 0.3f);         // 最大像素数（排除大块UI）

    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            if (detectMap[y * width + x] == 0 || labels[y * width + x] != 0) continue;

            // BFS 标记连通区域
            int label = currentLabel++;
            int pixelCount = 0;
            size_t minX = x, maxX = x, minY = y, maxY = y;

            size_t head = 0, tail = 0;
            queueX[tail] = x; queueY[tail] = y; tail++;
            labels[y * width + x] = label;

            while (head < tail) {
                size_t cx = queueX[head];
                size_t cy = queueY[head];
                head++;
                pixelCount++;

                if (cx < minX) minX = cx;
                if (cx > maxX) maxX = cx;
                if (cy < minY) minY = cy;
                if (cy > maxY) maxY = cy;

                // 检查 4 邻域
                int neighbors[4][2] = {{-1, 0}, {1, 0}, {0, -1}, {0, 1}};
                for (int n = 0; n < 4; n++) {
                    int nx = (int)cx + neighbors[n][0];
                    int ny = (int)cy + neighbors[n][1];
                    if (nx < 0 || nx >= (int)width || ny < 0 || ny >= (int)height) continue;
                    if (detectMap[ny * width + nx] != 0 && labels[ny * width + nx] == 0) {
                        labels[ny * width + nx] = label;
                        if (tail < queueCapacity) {
                            queueX[tail] = nx;
                            queueY[tail] = ny;
                            tail++;
                        }
                    }
                }
            }

            // 过滤过小或过大的区域
            if (pixelCount < minPixels || pixelCount > maxPixels) continue;

            // 计算实体的屏幕坐标（映射回原始分辨率）
            CGFloat scaleX = origSize.width / (CGFloat)width;
            CGFloat scaleY = origSize.height / (CGFloat)height;

            CGFloat screenX = (minX + maxX) * 0.5f * scaleX;
            CGFloat screenY = (minY + maxY) * 0.5f * scaleY;
            CGFloat boxW = (maxX - minX + 1) * scaleX;
            CGFloat boxH = (maxY - minY + 1) * scaleY;

            // 过滤屏幕边缘的 UI 元素（血条通常在边缘）
            if (screenX < 20 || screenX > origSize.width - 20) continue;
            if (screenY < 20 || screenY > origSize.height - 20) continue;

            // 长宽比过滤：玩家方框通常高度 > 宽度
            if (boxH < boxW * 0.5f) continue;

            // 去重：检查是否与已检测到的实体重叠
            BOOL duplicate = NO;
            for (ESPPlayerData *existing in results) {
                CGFloat dx = existing.screenPos.x - screenX;
                CGFloat dy = existing.screenPos.y - screenY;
                if (sqrtf(dx * dx + dy * dy) < 40.0f) {
                    duplicate = YES;
                    break;
                }
            }
            if (duplicate) continue;

            // 创建 ESP 数据
            ESPPlayerData *entity = [[ESPPlayerData alloc] init];
            entity.isValid = YES;
            entity.isEnemy = YES;
            entity.screenPos = CGPointMake(screenX, screenY);
            entity.health = 1.0f;
            entity.name = [NSString stringWithFormat:@"E%lu", (unsigned long)(results.count + 1)];
            entity.hasBones = YES;
            entity.boxRect = CGRectMake(screenX - boxW * 0.5f,
                                        screenY - boxH * 0.5f,
                                        boxW, boxH);

            // 生成骨骼数据（基于检测到的边界框）
            CGFloat headY = screenY - boxH * 0.4f;
            entity->bonePositions[ESPBoneHead]      = CGPointMake(screenX, headY);
            entity->bonePositions[ESPBoneNeck]      = CGPointMake(screenX, headY + boxH * 0.08f);
            entity->bonePositions[ESPBoneChest]     = CGPointMake(screenX, screenY - boxH * 0.1f);
            entity->bonePositions[ESPBonePelvis]    = CGPointMake(screenX, screenY + boxH * 0.1f);
            entity->bonePositions[ESPBoneLUpperArm] = CGPointMake(screenX - boxW * 0.25f, screenY - boxH * 0.15f);
            entity->bonePositions[ESPBoneLForearm]  = CGPointMake(screenX - boxW * 0.3f, screenY);
            entity->bonePositions[ESPBoneLHand]     = CGPointMake(screenX - boxW * 0.25f, screenY + boxH * 0.15f);
            entity->bonePositions[ESPBoneRUpperArm] = CGPointMake(screenX + boxW * 0.25f, screenY - boxH * 0.15f);
            entity->bonePositions[ESPBoneRForearm]  = CGPointMake(screenX + boxW * 0.3f, screenY);
            entity->bonePositions[ESPBoneRHand]     = CGPointMake(screenX + boxW * 0.25f, screenY + boxH * 0.15f);
            entity->bonePositions[ESPBoneLThigh]    = CGPointMake(screenX - boxW * 0.15f, screenY + boxH * 0.2f);
            entity->bonePositions[ESPBoneLShin]     = CGPointMake(screenX - boxW * 0.12f, screenY + boxH * 0.35f);
            entity->bonePositions[ESPBoneLFoot]     = CGPointMake(screenX - boxW * 0.15f, screenY + boxH * 0.48f);
            entity->bonePositions[ESPBoneRThigh]    = CGPointMake(screenX + boxW * 0.15f, screenY + boxH * 0.2f);
            entity->bonePositions[ESPBoneRShin]     = CGPointMake(screenX + boxW * 0.12f, screenY + boxH * 0.35f);
            entity->bonePositions[ESPBoneRFoot]     = CGPointMake(screenX + boxW * 0.15f, screenY + boxH * 0.48f);

            [results addObject:entity];

            // 最多保留 8 个实体
            if (results.count >= 8) break;
        }
        if (results.count >= 8) break;
    }

    // 清理
    free(detectMap);
    free(labels);
    free(queueX);
    free(queueY);

    return results;
}

@end
