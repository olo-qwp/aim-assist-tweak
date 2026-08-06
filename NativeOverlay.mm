#import "NativeOverlay.h"
#import "AimAssistManager.h"
#import "ESPManager.h"
#import <QuartzCore/QuartzCore.h>

// ═══════════════════════════════════════════════════════════════════════════
//  ESP 演示数据生成器
//  在实际游戏内存读取代码接入前，生成演示数据供测试
//  接入游戏数据后，将 ESPManager updatePlayers: 替换为实际数据即可
// ═══════════════════════════════════════════════════════════════════════════
@interface ESPDemoDataGenerator : NSObject
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) CGFloat angle;
- (void)start;
- (void)stop;
@end

@implementation ESPDemoDataGenerator

- (void)start {
    _angle = 0;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                              target:self
                                            selector:@selector(generateDemoData)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)stop {
    [_timer invalidate];
    _timer = nil;
}

- (void)generateDemoData {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat cx = screen.width * 0.5;
    CGFloat cy = screen.height * 0.5;

    _angle += 0.02;

    // 生成3个演示敌人
    NSMutableArray *players = [NSMutableArray array];

    // 敌人1 - 在屏幕右侧移动（模拟敌人）
    ESPPlayerData *p1 = [[ESPPlayerData alloc] init];
    p1.isValid = YES;
    p1.isEnemy = YES;
    p1.health = 0.75;
    p1.name = @"Enemy-1";
    CGFloat e1x = cx + 150 * cos(_angle);
    CGFloat e1y = cy - 100 + 80 * sin(_angle * 0.7);
    p1.screenPos = CGPointMake(e1x, e1y);
    p1.boxRect = CGRectMake(e1x - 20, e1y - 40, 40, 80);
    // 骨骼数据
    p1.hasBones = YES;
    CGFloat headY = e1y - 40;
    p1->bonePositions[ESPBoneHead]      = CGPointMake(e1x, headY);
    p1->bonePositions[ESPBoneNeck]      = CGPointMake(e1x, headY + 12);
    p1->bonePositions[ESPBoneChest]     = CGPointMake(e1x, headY + 22);
    p1->bonePositions[ESPBonePelvis]    = CGPointMake(e1x, headY + 42);
    p1->bonePositions[ESPBoneLUpperArm] = CGPointMake(e1x - 14, headY + 14);
    p1->bonePositions[ESPBoneLForearm]  = CGPointMake(e1x - 18, headY + 28);
    p1->bonePositions[ESPBoneLHand]     = CGPointMake(e1x - 16, headY + 38);
    p1->bonePositions[ESPBoneRUpperArm] = CGPointMake(e1x + 14, headY + 14);
    p1->bonePositions[ESPBoneRForearm]  = CGPointMake(e1x + 18, headY + 28);
    p1->bonePositions[ESPBoneRHand]     = CGPointMake(e1x + 16, headY + 38);
    p1->bonePositions[ESPBoneLThigh]    = CGPointMake(e1x - 8,  headY + 50);
    p1->bonePositions[ESPBoneLShin]     = CGPointMake(e1x - 6,  headY + 70);
    p1->bonePositions[ESPBoneLFoot]     = CGPointMake(e1x - 8,  headY + 85);
    p1->bonePositions[ESPBoneRThigh]    = CGPointMake(e1x + 8,  headY + 50);
    p1->bonePositions[ESPBoneRShin]     = CGPointMake(e1x + 6,  headY + 70);
    p1->bonePositions[ESPBoneRFoot]     = CGPointMake(e1x + 8,  headY + 85);
    [players addObject:p1];

    // 敌人2 - 在屏幕左侧（自动瞄准不处理，因为是左半屏）
    ESPPlayerData *p2 = [[ESPPlayerData alloc] init];
    p2.isValid = YES;
    p2.isEnemy = YES;
    p2.health = 0.45;
    p2.name = @"Enemy-2";
    CGFloat e2x = 120 + 60 * sin(_angle * 0.5);
    CGFloat e2y = cy - 50;
    p2.screenPos = CGPointMake(e2x, e2y);
    p2.boxRect = CGRectMake(e2x - 18, e2y - 36, 36, 72);
    p2.hasBones = YES;
    CGFloat h2y = e2y - 36;
    p2->bonePositions[ESPBoneHead]      = CGPointMake(e2x, h2y);
    p2->bonePositions[ESPBoneNeck]      = CGPointMake(e2x, h2y + 10);
    p2->bonePositions[ESPBoneChest]     = CGPointMake(e2x, h2y + 20);
    p2->bonePositions[ESPBonePelvis]    = CGPointMake(e2x, h2y + 38);
    p2->bonePositions[ESPBoneLUpperArm] = CGPointMake(e2x - 12, h2y + 12);
    p2->bonePositions[ESPBoneLForearm]  = CGPointMake(e2x - 16, h2y + 24);
    p2->bonePositions[ESPBoneLHand]     = CGPointMake(e2x - 14, h2y + 34);
    p2->bonePositions[ESPBoneRUpperArm] = CGPointMake(e2x + 12, h2y + 12);
    p2->bonePositions[ESPBoneRForearm]  = CGPointMake(e2x + 16, h2y + 24);
    p2->bonePositions[ESPBoneRHand]     = CGPointMake(e2x + 14, h2y + 34);
    p2->bonePositions[ESPBoneLThigh]    = CGPointMake(e2x - 7,  h2y + 46);
    p2->bonePositions[ESPBoneLShin]     = CGPointMake(e2x - 5,  h2y + 64);
    p2->bonePositions[ESPBoneLFoot]     = CGPointMake(e2x - 7,  h2y + 78);
    p2->bonePositions[ESPBoneRThigh]    = CGPointMake(e2x + 7,  h2y + 46);
    p2->bonePositions[ESPBoneRShin]     = CGPointMake(e2x + 5,  h2y + 64);
    p2->bonePositions[ESPBoneRFoot]     = CGPointMake(e2x + 7,  h2y + 78);
    [players addObject:p2];

    // 敌人3 - 在屏幕上方
    ESPPlayerData *p3 = [[ESPPlayerData alloc] init];
    p3.isValid = YES;
    p3.isEnemy = NO; // 友军
    p3.health = 0.9;
    p3.name = @"Teammate";
    CGFloat e3x = cx + 80 * sin(_angle * 0.3);
    CGFloat e3y = 120 + 40 * sin(_angle * 0.5);
    p3.screenPos = CGPointMake(e3x, e3y);
    p3.boxRect = CGRectMake(e3x - 18, e3y - 36, 36, 72);
    p3.hasBones = YES;
    CGFloat h3y = e3y - 36;
    p3->bonePositions[ESPBoneHead]      = CGPointMake(e3x, h3y);
    p3->bonePositions[ESPBoneNeck]      = CGPointMake(e3x, h3y + 10);
    p3->bonePositions[ESPBoneChest]     = CGPointMake(e3x, h3y + 20);
    p3->bonePositions[ESPBonePelvis]    = CGPointMake(e3x, h3y + 38);
    p3->bonePositions[ESPBoneLUpperArm] = CGPointMake(e3x - 12, h3y + 12);
    p3->bonePositions[ESPBoneLForearm]  = CGPointMake(e3x - 16, h3y + 24);
    p3->bonePositions[ESPBoneLHand]     = CGPointMake(e3x - 14, h3y + 34);
    p3->bonePositions[ESPBoneRUpperArm] = CGPointMake(e3x + 12, h3y + 12);
    p3->bonePositions[ESPBoneRForearm]  = CGPointMake(e3x + 16, h3y + 24);
    p3->bonePositions[ESPBoneRHand]     = CGPointMake(e3x + 14, h3y + 34);
    p3->bonePositions[ESPBoneLThigh]    = CGPointMake(e3x - 7,  h3y + 46);
    p3->bonePositions[ESPBoneLShin]     = CGPointMake(e3x - 5,  h3y + 64);
    p3->bonePositions[ESPBoneLFoot]     = CGPointMake(e3x - 7,  h3y + 78);
    p3->bonePositions[ESPBoneRThigh]    = CGPointMake(e3x + 7,  h3y + 46);
    p3->bonePositions[ESPBoneRShin]     = CGPointMake(e3x + 5,  h3y + 64);
    p3->bonePositions[ESPBoneRFoot]     = CGPointMake(e3x + 7,  h3y + 78);
    [players addObject:p3];

    [[ESPManager sharedManager] updatePlayers:players];
}

@end

// ═══════════════════════════════════════════════════════════════════════════
//  ESP 绘制视图 — 覆盖全屏，绘制骨骼/方框/准心/FOV
//  userInteractionEnabled = NO，不拦截触摸
// ═══════════════════════════════════════════════════════════════════════════
@interface ESPDrawView : UIView
@property (nonatomic, strong) CADisplayLink *displayLink;
@end

@implementation ESPDrawView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;

        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLink:)];
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc {
    [_displayLink invalidate];
}

- (void)onDisplayLink:(CADisplayLink *)sender {
    [self setNeedsDisplay];
}

// ═══════════════════════════════════════════════════════════════════════════
//  Core Graphics 绘制入口
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGSize screen = self.bounds.size;
    CGFloat cx = screen.width * 0.5f;
    CGFloat cy = screen.height * 0.5f;

    ESPManager *esp = [ESPManager sharedManager];
    AimAssistManager *aa = [AimAssistManager sharedManager];

    // ── 1. 绘制 FOV 圈（始终显示，表示自瞄范围） ──
    if (aa.fovEnabled && aa.fovRadius > 0) {
        [self drawFOVCircleAt:CGPointMake(cx, cy) radius:aa.fovRadius context:ctx];
    }

    // ── 2. 绘制准心 ──
    if (esp.showCrosshair) {
        [self drawCrosshairAt:CGPointMake(cx, cy) context:ctx];
    }

    // ── 3. 绘制 ESP 数据 ──
    if (esp.espEnabled) {
        NSArray *players = [esp currentPlayers];
        for (ESPPlayerData *p in players) {
            if (!p.isValid) continue;

            // 骨骼（在方框下面）
            if (esp.showSkeleton && p.hasBones) {
                [self drawSkeleton:p context:ctx];
            }

            // 方框
            if (esp.showBox && !CGRectIsEmpty(p.boxRect)) {
                UIColor *color = p.isEnemy ? [UIColor redColor] : [UIColor greenColor];
                [self drawBox:p.boxRect color:color context:ctx];
            }

            // 血条
            if (esp.showHealth && !CGRectIsEmpty(p.boxRect)) {
                [self drawHealthBar:p.boxRect health:p.health context:ctx];
            }

            // 名字
            if (esp.showName && p.name.length > 0) {
                [self drawName:p.name at:p.screenPos context:ctx];
            }

            // 如果ESP开启且自瞄开启，标记锁定目标（最近敌人头部高亮）
            if (aa.enabled && p.isEnemy && p.hasBones) {
                CGPoint head = p->bonePositions[ESPBoneHead];
                CGFloat hdx = head.x - cx;
                CGFloat hdy = head.y - cy;
                CGFloat hdist = sqrtf(hdx * hdx + hdy * hdy);
                if (hdist < aa.fovRadius) {
                    // 绘制目标指示线（从准心到敌人头部）
                    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:0.3].CGColor);
                    CGContextSetLineWidth(ctx, 1.0);
                    CGFloat dashes[] = {4, 4};
                    CGContextSetLineDash(ctx, 0, dashes, 2);
                    CGContextBeginPath(ctx);
                    CGContextMoveToPoint(ctx, cx, cy);
                    CGContextAddLineToPoint(ctx, head.x, head.y);
                    CGContextStrokePath(ctx);
                    CGContextSetLineDash(ctx, 0, NULL, 0);
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  绘制准心
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawCrosshairAt:(CGPoint)center context:(CGContextRef)ctx {
    CGFloat len = 15.0f;
    CGFloat gap = 5.0f;
    CGFloat w = 2.0f;

    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.0 green:1.0 blue:0.3 alpha:0.9].CGColor);
    CGContextSetLineWidth(ctx, w);

    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, center.x, center.y - gap);
    CGContextAddLineToPoint(ctx, center.x, center.y - gap - len);
    CGContextMoveToPoint(ctx, center.x, center.y + gap);
    CGContextAddLineToPoint(ctx, center.x, center.y + gap + len);
    CGContextMoveToPoint(ctx, center.x - gap, center.y);
    CGContextAddLineToPoint(ctx, center.x - gap - len, center.y);
    CGContextMoveToPoint(ctx, center.x + gap, center.y);
    CGContextAddLineToPoint(ctx, center.x + gap + len, center.y);
    CGContextStrokePath(ctx);

    // 中心点
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.3 blue:0.0 alpha:0.9].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(center.x - 3, center.y - 3, 6, 6));
}

// ═══════════════════════════════════════════════════════════════════════════
//  绘制 FOV 圈
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawFOVCircleAt:(CGPoint)center radius:(CGFloat)r context:(CGContextRef)ctx {
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:0.6].CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGFloat dashes[] = {8, 4};
    CGContextSetLineDash(ctx, 0, dashes, 2);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(center.x - r, center.y - r, r * 2, r * 2));
    CGContextSetLineDash(ctx, 0, NULL, 0);
}

// ═══════════════════════════════════════════════════════════════════════════
//  绘制骨骼
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawSkeleton:(ESPPlayerData *)p context:(CGContextRef)ctx {
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:0.9].CGColor);
    CGContextSetLineWidth(ctx, 2.0);

    for (int i = 0; ; i += 2) {
        int from = ESPBoneConnections[i];
        int to = ESPBoneConnections[i + 1];
        if (from < 0 || to < 0) break;

        CGPoint pf = p->bonePositions[from];
        CGPoint pt = p->bonePositions[to];
        if (pf.x <= 0 && pf.y <= 0) continue;
        if (pt.x <= 0 && pt.y <= 0) continue;

        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, pf.x, pf.y);
        CGContextAddLineToPoint(ctx, pt.x, pt.y);
        CGContextStrokePath(ctx);
    }

    // 头部高亮圆圈
    CGPoint head = p->bonePositions[ESPBoneHead];
    if (head.x > 0 || head.y > 0) {
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:0.9].CGColor);
        CGContextSetLineWidth(ctx, 2.5);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(head.x - 8, head.y - 8, 16, 16));
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  绘制方框
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawBox:(CGRect)rect color:(UIColor *)color context:(CGContextRef)ctx {
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextStrokeRect(ctx, rect);
}

// ═══════════════════════════════════════════════════════════════════════════
//  绘制血条
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawHealthBar:(CGRect)box health:(CGFloat)health context:(CGContextRef)ctx {
    CGFloat barW = 4;
    CGFloat barH = box.size.height;
    CGFloat barX = box.origin.x - barW - 2;
    CGFloat barY = box.origin.y;

    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.2 alpha:0.8].CGColor);
    CGContextFillRect(ctx, CGRectMake(barX, barY, barW, barH));

    CGFloat fillH = barH * MAX(0, MIN(1, health));
    UIColor *healthColor = health > 0.6 ? [UIColor greenColor] :
                           health > 0.3 ? [UIColor yellowColor] : [UIColor redColor];
    CGContextSetFillColorWithColor(ctx, healthColor.CGColor);
    CGContextFillRect(ctx, CGRectMake(barX, barY + barH - fillH, barW, fillH));
}

// ═══════════════════════════════════════════════════════════════════════════
//  绘制名字
// ═══════════════════════════════════════════════════════════════════════════
- (void)drawName:(NSString *)name at:(CGPoint)pos context:(CGContextRef)ctx {
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    CGSize size = [name sizeWithAttributes:attrs];
    CGPoint drawPos = CGPointMake(pos.x - size.width * 0.5f, pos.y - 30);
    [name drawAtPoint:drawPos withAttributes:attrs];
}

@end

// ═══════════════════════════════════════════════════════════════════════════
//  全屏浮窗窗口 — 用于控制按钮和触摸穿透
// ═══════════════════════════════════════════════════════════════════════════
@interface OverlayWindow : UIWindow
@property (nonatomic, weak) UIView *controlView;
@end

@implementation OverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.controlView && !self.controlView.hidden && self.controlView.alpha > 0.0) {
        CGPoint cp = [self.controlView convertPoint:point fromView:self];
        if (CGRectContainsPoint(self.controlView.bounds, cp)) {
            UIView *hit = [super hitTest:point withEvent:event];
            if (hit && hit != self) return hit;
        }
    }
    return nil;
}

@end

// ═══════════════════════════════════════════════════════════════════════════
//  可拖拽控制面板
// ═══════════════════════════════════════════════════════════════════════════
@interface ControlPanel : UIView
@end

@implementation ControlPanel {
    CGPoint _dragStartCenter;
    CGPoint _dragStartTouch;
    BOOL _minimized;
    CGPoint _savedCenter;
    UIView *_minimizedView;
    UIView *_fullView;
    UILabel *_statusLabel;
    UILabel *_aimStatusLabel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _minimized = NO;
        [self setupFullMode];
        [self setupMinimizedMode];
        [self showFullMode];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

// ── 全屏模式 ──
- (void)setupFullMode {
    _fullView = [[UIView alloc] initWithFrame:self.bounds];
    _fullView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _fullView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.85];
    _fullView.layer.cornerRadius = 14;
    _fullView.layer.shadowColor = [UIColor blackColor].CGColor;
    _fullView.layer.shadowOpacity = 0.6;
    _fullView.layer.shadowRadius = 12;
    _fullView.layer.shadowOffset = CGSizeMake(0, 4);
    [self addSubview:_fullView];

    CGFloat w = self.bounds.size.width;
    CGFloat cy = 12;

    // 标题行
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, w - 50, 26)];
    title.text = @"ESP+Aim Assist";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:15];
    [_fullView addSubview:title];

    // 最小化按钮
    UIButton *minBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    minBtn.frame = CGRectMake(w - 34, 9, 28, 28);
    minBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.6];
    minBtn.layer.cornerRadius = 14;
    minBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [minBtn setTitle:@"─" forState:UIControlStateNormal];
    [minBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [minBtn addTarget:self action:@selector(minimize) forControlEvents:UIControlEventTouchUpInside];
    [_fullView addSubview:minBtn];
    cy += 30;

    // ── 自瞄开关 ──
    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, 80, 26)];
    l1.text = @"自瞄";
    l1.textColor = [UIColor whiteColor];
    l1.font = [UIFont systemFontOfSize:13];
    [_fullView addSubview:l1];

    UISwitch *aimSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 58, cy - 1, 48, 26)];
    aimSwitch.on = [AimAssistManager sharedManager].enabled;
    aimSwitch.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [aimSwitch addTarget:self action:@selector(aimToggled:) forControlEvents:UIControlEventValueChanged];
    [_fullView addSubview:aimSwitch];
    cy += 28;

    // ── ESP 开关 ──
    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, 80, 26)];
    l2.text = @"ESP透视";
    l2.textColor = [UIColor whiteColor];
    l2.font = [UIFont systemFontOfSize:13];
    [_fullView addSubview:l2];

    UISwitch *espSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 58, cy - 1, 48, 26)];
    espSwitch.on = [ESPManager sharedManager].espEnabled;
    espSwitch.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [espSwitch addTarget:self action:@selector(espToggled:) forControlEvents:UIControlEventValueChanged];
    [_fullView addSubview:espSwitch];
    cy += 28;

    // ── 骨骼开关 ──
    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, 80, 26)];
    l3.text = @"骨骼";
    l3.textColor = [UIColor whiteColor];
    l3.font = [UIFont systemFontOfSize:13];
    [_fullView addSubview:l3];

    UISwitch *boneSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 58, cy - 1, 48, 26)];
    boneSwitch.on = [ESPManager sharedManager].showSkeleton;
    boneSwitch.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [boneSwitch addTarget:self action:@selector(boneToggled:) forControlEvents:UIControlEventValueChanged];
    [_fullView addSubview:boneSwitch];
    cy += 28;

    // ── 方框开关 ──
    UILabel *l4 = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, 80, 26)];
    l4.text = @"方框";
    l4.textColor = [UIColor whiteColor];
    l4.font = [UIFont systemFontOfSize:13];
    [_fullView addSubview:l4];

    UISwitch *boxSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 58, cy - 1, 48, 26)];
    boxSwitch.on = [ESPManager sharedManager].showBox;
    boxSwitch.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [boxSwitch addTarget:self action:@selector(boxToggled:) forControlEvents:UIControlEventValueChanged];
    [_fullView addSubview:boxSwitch];
    cy += 28;

    // 状态标签
    _aimStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, w - 20, 18)];
    _aimStatusLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    _aimStatusLabel.font = [UIFont systemFontOfSize:10];
    _aimStatusLabel.text = [AimAssistManager sharedManager].enabled ? @"自瞄: 开 | 目标: 头部" : @"自瞄: 关";
    [_fullView addSubview:_aimStatusLabel];
    cy += 20;

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, cy, w - 20, 18)];
    _statusLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    _statusLabel.font = [UIFont systemFontOfSize:9];
    _statusLabel.text = @"右半屏瞄准 | 自动锁定FOV内敌人";
    [_fullView addSubview:_statusLabel];
}

// ── 最小化模式 ──
- (void)setupMinimizedMode {
    _minimizedView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    _minimizedView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _minimizedView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.85];
    _minimizedView.layer.cornerRadius = 22;
    _minimizedView.layer.shadowColor = [UIColor blackColor].CGColor;
    _minimizedView.layer.shadowOpacity = 0.6;
    _minimizedView.layer.shadowRadius = 8;
    _minimizedView.layer.shadowOffset = CGSizeMake(0, 2);
    _minimizedView.hidden = YES;
    [self addSubview:_minimizedView];

    UILabel *icon = [[UILabel alloc] initWithFrame:_minimizedView.bounds];
    icon.text = @"⚡";
    icon.textAlignment = NSTextAlignmentCenter;
    icon.font = [UIFont systemFontOfSize:20];
    [_minimizedView addSubview:icon];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(restore)];
    [_minimizedView addGestureRecognizer:tap];
}

- (void)showFullMode {
    _fullView.hidden = NO;
    _minimizedView.hidden = YES;
    CGRect f = self.frame;
    f.size = CGSizeMake(170, 210);
    self.frame = f;
    _fullView.frame = self.bounds;
    [self layoutSubviews];
}

- (void)minimize {
    _minimized = YES;
    _fullView.hidden = YES;
    _minimizedView.hidden = NO;
    _savedCenter = self.center;
    CGRect f = self.frame;
    f.size = CGSizeMake(44, 44);
    self.frame = f;
    _minimizedView.frame = self.bounds;
    [self layoutSubviews];
}

- (void)restore {
    _minimized = NO;
    self.center = _savedCenter;
    [self showFullMode];
}

// ── 控件事件 ──
- (void)aimToggled:(UISwitch *)s {
    [AimAssistManager sharedManager].enabled = s.on;
    [[AimAssistManager sharedManager] saveSettings];
    _aimStatusLabel.text = s.on ? @"自瞄: 开 | 目标: 头部" : @"自瞄: 关";
}

- (void)espToggled:(UISwitch *)s {
    [ESPManager sharedManager].espEnabled = s.on;
    if (!s.on) {
        // 关闭ESP时也清除演示数据
        [[ESPManager sharedManager] updatePlayers:@[]];
    }
}

- (void)boneToggled:(UISwitch *)s {
    [ESPManager sharedManager].showSkeleton = s.on;
}

- (void)boxToggled:(UISwitch *)s {
    [ESPManager sharedManager].showBox = s.on;
}

// ── 拖拽 ──
- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (_minimized) return;
    CGPoint loc = [g locationInView:self.superview];
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            _dragStartCenter = self.center;
            _dragStartTouch = loc;
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat dx = loc.x - _dragStartTouch.x;
            CGFloat dy = loc.y - _dragStartTouch.y;
            CGPoint newCenter = CGPointMake(_dragStartCenter.x + dx, _dragStartCenter.y + dy);
            CGSize screen = self.superview.bounds.size;
            CGFloat halfW = self.bounds.size.width * 0.5;
            CGFloat halfH = self.bounds.size.height * 0.5;
            newCenter.x = MAX(halfW, MIN(screen.width - halfW, newCenter.x));
            newCenter.y = MAX(halfH, MIN(screen.height - halfH, newCenter.y));
            self.center = newCenter;
            break;
        }
        default:
            break;
    }
}

@end

// ═══════════════════════════════════════════════════════════════════════════
//  NativeOverlay 主实现
// ═══════════════════════════════════════════════════════════════════════════
@implementation NativeOverlay {
    OverlayWindow *_overlayWindow;  // 控制面板窗口
    ControlPanel *_panelView;       // 控制面板
    ESPDrawView *_espView;         // ESP 绘制视图（添加到游戏主窗口）
    ESPDemoDataGenerator *_demoGen; // 演示数据生成器
}

+ (instancetype)sharedOverlay {
    static NativeOverlay *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[NativeOverlay alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _demoGen = [[ESPDemoDataGenerator alloc] init];
        [self setupESPView];
        [self setupPanelWindow];
        [self setupPanel];
    }
    return self;
}

// ── 创建 ESP 绘制视图，添加到游戏主窗口 ──
- (void)setupESPView {
    UIWindow *keyWindow = [self findKeyWindow];
    if (keyWindow) {
        _espView = [[ESPDrawView alloc] initWithFrame:keyWindow.bounds];
        _espView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [keyWindow addSubview:_espView];
        [_demoGen start];
    }
}

// ── 查找关键窗口 ──
- (UIWindow *)findKeyWindow {
    if (@available(iOS 13.0, *)) {
        NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
        for (UIScene *scene in scenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in ws.windows) {
                        if (w.isKeyWindow) return w;
                    }
                }
            }
        }
        // 兜底
        for (UIScene *scene in scenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) return w;
                }
            }
        }
    }
    if ([UIApplication sharedApplication].keyWindow)
        return [UIApplication sharedApplication].keyWindow;
    return [UIApplication sharedApplication].windows.firstObject;
}

// ── 创建控制面板窗口 ──
- (void)setupPanelWindow {
    UIWindowScene *scene = nil;
    if (@available(iOS 13.0, *)) {
        NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
        for (UIScene *s in scenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s;
                break;
            }
        }
        if (!scene) {
            for (UIScene *s in scenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
            }
        }
    }

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    if (@available(iOS 13.0, *)) {
        _overlayWindow = [[OverlayWindow alloc] initWithWindowScene:scene];
        _overlayWindow.frame = screenBounds;
    } else {
        _overlayWindow = [[OverlayWindow alloc] initWithFrame:screenBounds];
    }

    _overlayWindow.windowLevel = UIWindowLevelStatusBar + 200;
    _overlayWindow.backgroundColor = [UIColor clearColor];
    _overlayWindow.opaque = NO;
    _overlayWindow.hidden = NO;
    _overlayWindow.rootViewController = [[UIViewController alloc] init];
}

// ── 创建控制面板 ──
- (void)setupPanel {
    CGFloat pw = 170, ph = 210;
    CGFloat px = 16, py = 100;

    _panelView = [[ControlPanel alloc] initWithFrame:CGRectMake(px, py, pw, ph)];
    _panelView.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    _overlayWindow.controlView = _panelView;
    [_overlayWindow addSubview:_panelView];
}

// ── 公共接口 ──
- (void)show {
    _overlayWindow.hidden = NO;
    if (!_espView || !_espView.superview) {
        [self setupESPView];
    }
    UIWindow *kw = [self findKeyWindow];
    if (kw) _espView.frame = kw.bounds;
    if (!_demoGen.timer) [_demoGen start];
}

- (void)hide {
    _overlayWindow.hidden = YES;
    [_espView removeFromSuperview];
    _espView = nil;
    [_demoGen stop];
}

- (BOOL)isVisible {
    return !_overlayWindow.hidden;
}

- (void)setNeedsDisplay {
    [_espView setNeedsDisplay];
}

- (CGRect)panelFrame {
    if (!_panelView || _panelView.hidden || _panelView.alpha < 0.01) return CGRectNull;
    return _panelView.frame;
}

@end