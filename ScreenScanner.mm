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

    // 多帧确认跟踪列表（仅后台队列访问）
    NSMutableArray<ESPPlayerData *> *_tracked;
    int _emptyFrames;            // 连续无检测帧计数
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
        _emptyFrames = 0;
        _tracked = [NSMutableArray array];
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
    // 排空后台队列再释放资源（避免与进行中的分析竞争）
    dispatch_sync(_scanQueue, ^{
        if (_prevFrameData) {
            free(_prevFrameData);
            _prevFrameData = NULL;
            _prevFrameSize = 0;
        }
        [_tracked removeAllObjects];
    });
}

// ═══════════════════════════════════════════════════════════════════════════
//  主扫描逻辑 — 主线程只做低分辨率截图，像素分析全部在后台队列
//  (A11 60fps: 主线程每帧开销 ~2-4ms 截图渲染，重循环不占主线程)
// ═══════════════════════════════════════════════════════════════════════════

- (void)performScan {
    @autoreleasepool {
        if (_busy || !_isScanning) return;
        // 内存模型检测到真实敌人时，屏幕识别完全让位（避免覆盖精确数据）
        if ([[ESPManager sharedManager] memoryActive]) return;
        _busy = YES;
        _frameCount++;

        // 直接以 1/4 线性分辨率截屏（=1/16 像素量，省去全分辨率+降采样两趟）
        UIImage *screenshot = [self captureScreen];
        if (!screenshot) { _busy = NO; return; }
        CGSize origSize = [UIScreen mainScreen].bounds.size;

        dispatch_async(_scanQueue, ^{
            @autoreleasepool {
                // 分析图像，检测候选敌人（颜色/运动/聚类，全在后台）
                NSArray<ESPPlayerData *> *cands =
                    [self detectEnemiesInImage:screenshot originalSize:origSize];
                // 多帧确认：同一位置连续 ≥2 帧出现才算真敌人（大幅抑制误报）
                NSArray<ESPPlayerData *> *entities = [self stabilize:cands];
                BOOL stillScanning = _isScanning;

                dispatch_async(dispatch_get_main_queue(), ^{
                    _busy = NO;
                    if (!stillScanning) return;

                    // 更新 ESP 数据
                    if (entities.count > 0) {
                        [[ESPManager sharedManager] updatePlayers:entities];
                        [[ESPManager sharedManager] setDataSource:@"屏幕识别"];
                        _emptyFrames = 0;
                    } else {
                        // 连续多帧无数据后清空
                        _emptyFrames++;
                        if (_emptyFrames > 5) {
                            [[ESPManager sharedManager] updatePlayers:@[]];
                            _emptyFrames = 0;
                        }
                    }
                });
            }
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  多帧确认 — 候选与上一帧位置匹配（<60pt）则计数+1，连续 ≥2 帧才输出。
//  单帧闪现的红色 UI / 伤害数字 / 特效不再被当作敌人。
//  (ponytail: O(n²) 线性匹配，≤8 实体无压力；半径 60pt 适合 10fps 帧率)
// ═══════════════════════════════════════════════════════════════════════════
- (NSArray<ESPPlayerData *> *)stabilize:(NSArray<ESPPlayerData *> *)cands {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *next = [NSMutableArray arrayWithCapacity:cands.count];
    for (ESPPlayerData *c in cands) {
        ESPPlayerData *best = nil;
        CGFloat bestD = 60.0f;
        for (ESPPlayerData *t in _tracked) {
            CGFloat d = hypotf(c.screenPos.x - t.screenPos.x, c.screenPos.y - t.screenPos.y);
            if (d < bestD) { bestD = d; best = t; }
        }
        c->stableCount = best ? best->stableCount + 1 : 1;
        if (c->stableCount >= 2) [out addObject:c];
        [next addObject:c];
    }
    _tracked = next;
    return out;
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
    // 每个像素标记为：0=背景, 1=敌人色, 2=运动, 3=肤色
    UInt8 *detectMap = (UInt8 *)calloc(width * height, sizeof(UInt8));
    if (!detectMap) return @[];

    // ── 颜色检测（收紧阈值 + 饱和度约束，排除暗红/粉红 UI） ──
    int base = (int)(160.0f + (1.0f - _sensitivity) * 40.0f); // 160~200：灵敏度越高阈值越低

    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            size_t idx = (y * width + x) * 4;
            UInt8 r = pixels[idx];
            UInt8 g = pixels[idx + 1];
            UInt8 b = pixels[idx + 2];

            // 红色系（敌人血条/轮廓/伤害标记）：要求高饱和纯红
            if (r > base && g < 90 && b < 90 && (r - g) > 90 && (r - b) > 90) {
                detectMap[y * width + x] = 1;
                continue;
            }

            // 橙色系（敌人高亮标记）
            if (r > 210 && g > 110 && g < 190 && b < 80 && (r - b) > 130) {
                detectMap[y * width + x] = 1;
                continue;
            }

            // 品红/粉色系（部分游戏的敌人标记）
            if (r > 170 && b > 170 && g < 90 && (r - g) > 80 && (b - g) > 80) {
                detectMap[y * width + x] = 1;
                continue;
            }

            // 肤色（YCrCb 空间，经典范围）：头部/手部人形特征，
            // 用于二次鉴别"这堆红色像素是不是人"
            {
                int Y  = (int)(0.299f * r + 0.587f * g + 0.114f * b);
                int Cr = (int)(0.5f * r - 0.4187f * g - 0.0813f * b) + 128;
                int Cb = (int)(-0.1687f * r - 0.3313f * g + 0.5f * b) + 128;
                if (Y > 60 && Y < 230 && Cr >= 130 && Cr <= 175 && Cb >= 75 && Cb <= 130) {
                    if (detectMap[y * width + x] == 0) {
                        detectMap[y * width + x] = 3;
                    }
                }
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
            // 聚类只从颜色像素起始（运动像素只能辅助扩展，不能独立成簇 → 移动的 UI/特效不再误报）
            if (detectMap[y * width + x] != 1 || labels[y * width + x] != 0) continue;

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

            // ═══ 精度过滤（大幅抑制误报） ═══
            // 屏幕边缘 UI（血条/击杀提示通常在边缘）
            if (screenX < 20 || screenX > origSize.width - 20) continue;
            if (screenY < 20 || screenY > origSize.height - 20) continue;

            // 顶部 HUD 区（血条/小地图/队友列表）与底部操作区（虚拟摇杆/按钮）
            if (screenY < origSize.height * 0.10f) continue;
            if (screenY > origSize.height * 0.88f) continue;

            // 屏幕中心准心区（半径 45pt：准心/伤害数字常为红色，是主要误报源）
            {
                CGFloat ddx = screenX - origSize.width * 0.5f;
                CGFloat ddy = screenY - origSize.height * 0.5f;
                if (ddx * ddx + ddy * ddy < 45.0f * 45.0f) continue;
            }

            // 宽高比：人体框高显著大于宽（排除方形 UI 图标/文字）
            if (boxH < boxW * 1.2f) continue;
            if (boxH > boxW * 6.0f) continue; // 过细长（线条/光效）

            // 尺寸：太小是噪点/远距离忽略，太大是全屏特效
            if (boxH < origSize.height * 0.05f) continue;
            if (boxW > origSize.width * 0.5f) continue;

            // 填充率：人体是稀疏轮廓/骨架（低填充），实心色块是 UI 图标
            float fill = (float)pixelCount /
                         ((float)(maxX - minX + 1) * (float)(maxY - minY + 1));
            if (fill > 0.40f) continue;
            if (fill < 0.05f) continue;

            // ═══ 人形形态学验证（框内二次鉴别，抑制"红块非人"误报） ═══
            // 1) 头部肤色：框顶 1/6 区域肤色像素占比（人形必有脸/发）
            // 2) 颜色方差：人体多色（衣/肤/发），纯色 UI 图标方差低
            // 3) 实心敌人标记占比：标记本身占满框（豁免上述两条）
            size_t bw = maxX - minX + 1;
            size_t bh = maxY - minY + 1;
            size_t headH = bh / 6 + 1;
            if (headH > bh) headH = bh;
            int headSkin = 0, headTotal = 0;
            for (size_t hy = minY; hy < minY + headH; hy++) {
                for (size_t hx = minX; hx <= maxX; hx++) {
                    headTotal++;
                    if (detectMap[hy * width + hx] == 3) headSkin++;
                }
            }
            float headSkinRatio = headTotal > 0 ? (float)headSkin / headTotal : 0.0f;

            // 框内颜色方差（采样步进 2 降开销）
            long sumR = 0, sumG = 0, sumB = 0; int n = 0;
            for (size_t yy = minY; yy <= maxY; yy += 2) {
                for (size_t xx = minX; xx <= maxX; xx += 2) {
                    size_t idx = (yy * width + xx) * 4;
                    sumR += pixels[idx]; sumG += pixels[idx + 1]; sumB += pixels[idx + 2];
                    n++;
                }
            }
            float bodyVar = 0.0f;
            if (n > 0) {
                float avR = (float)sumR / n, avG = (float)sumG / n, avB = (float)sumB / n;
                float acc = 0.0f; int vn = 0;
                for (size_t yy = minY; yy <= maxY; yy += 2) {
                    for (size_t xx = minX; xx <= maxX; xx += 2) {
                        size_t idx = (yy * width + xx) * 4;
                        acc += fabsf(pixels[idx] - avR) + fabsf(pixels[idx + 1] - avG) + fabsf(pixels[idx + 2] - avB);
                        vn++;
                    }
                }
                bodyVar = vn > 0 ? acc / vn : 0.0f;
            }
            float enemyFill = (float)pixelCount / ((float)bw * (float)bh);

            // 判定：实心强标记 或 具备人形特征（头部肤色 / 多色方差）
            if (!(enemyFill > 0.12f || headSkinRatio > 0.015f || bodyVar > 18.0f)) continue;

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
            // 头部精化：框顶 1/6 区域有肤色 → 用肤色质心当真实头部（自瞄更准）
            CGFloat headY = screenY - boxH * 0.4f;
            if (headSkinRatio > 0.015f) {
                long skinSumX = 0, skinSumY = 0; int skinN = 0;
                for (size_t hy = minY; hy < minY + headH; hy++) {
                    for (size_t hx = minX; hx <= maxX; hx++) {
                        if (detectMap[hy * width + hx] == 3) {
                            skinSumX += hx; skinSumY += hy; skinN++;
                        }
                    }
                }
                if (skinN > 0) {
                    headY = ((float)skinSumY / skinN) * scaleY;
                }
            }
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
