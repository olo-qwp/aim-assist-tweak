#import "EnemyMemoryReader.h"
#import "ESPManager.h"
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>
#import <strings.h>

// ═══════════════════════════════════════════════════════════════════════════
//  il2cpp 导出 API（全部 dlsym 运行时探测，零编译期依赖）
//  Unity IL2CPP 长期稳定导出这些符号，即使游戏 strip 也会保留 il2cpp_*
// ═══════════════════════════════════════════════════════════════════════════
typedef void *(*il2cpp_domain_get_t)(void);
typedef void **(*il2cpp_domain_get_assemblies_t)(void *, size_t *);
typedef void *(*il2cpp_assembly_get_image_t)(void *);
typedef const char *(*il2cpp_image_get_name_t)(void *);
typedef void *(*il2cpp_class_from_name_t)(void *, const char *, const char *);
typedef void *(*il2cpp_class_get_method_from_name_t)(void *, const char *, int);
typedef void *(*il2cpp_runtime_invoke_t)(void *, void *, void **, void **);
typedef void *(*il2cpp_string_new_t)(const char *);
typedef size_t (*il2cpp_array_length_t)(void *);
typedef const uint16_t *(*il2cpp_string_chars_t)(void *);
typedef int32_t (*il2cpp_string_length_t)(void *);

static il2cpp_domain_get_t             g_domain_get;
static il2cpp_domain_get_assemblies_t  g_domain_get_assemblies;
static il2cpp_assembly_get_image_t     g_assembly_get_image;
static il2cpp_image_get_name_t         g_image_get_name;
static il2cpp_class_from_name_t        g_class_from_name;
static il2cpp_class_get_method_from_name_t       g_method_from_name;
static il2cpp_runtime_invoke_t         g_runtime_invoke;
static il2cpp_string_new_t             g_string_new;
static il2cpp_array_length_t           g_array_length;
static il2cpp_string_chars_t           g_string_chars;
static il2cpp_string_length_t          g_string_length;

// ── 敌人 tag 列表（FPS/动作游戏通用敌人标签） ──
static const char *kEnemyTags[] = {
    "Enemy", "Zombie", "Bot", "AI", "Monster", "Minion",
    "Target", "Guard", "Soldier", "Bandit", "Drone", "Mob"
};
static const int kEnemyTagCount = 12;

// ── 名称排除词（避免把友军/自己当敌人） ──
static const char *kExcludeNames[] = {
    "Player", "Ally", "Friend", "Team", "Friendly", "Hero", "Character"
};
static const int kExcludeNameCount = 7;

// ── arm64: Il2CppObject 头 16 字节(klass+monitor)，boxed struct 数据从 16 开始 ──
static float *AA_boxedFloats(void *boxed) { return (float *)((char *)boxed + 16); }

@interface EnemyMemoryReader () {
    dispatch_queue_t _queue;
    volatile BOOL _running;
    BOOL _unity;

    // 缓存的 Unity 类/方法句柄
    void *_gameObjectClass;
    void *_transformClass;
    void *_cameraClass;
    void *_mFindByTag;     // GameObject.FindGameObjectsWithTag(string)
    void *_mGetTransform;  // GameObject.get_transform
    void *_mGetName;       // GameObject.get_name
    void *_mGetPosition;   // Transform.get_position
    void *_mGetMain;       // Camera.get_main (static)
    void *_mGetWTC;        // Camera.get_worldToCameraMatrix
    void *_mGetProj;       // Camera.get_projectionMatrix

    float _vp[16];         // 投影矩阵 = projection * view（列主序）
    int _emptyCount;       // 连续空帧计数（≥3 时释放数据源让位屏幕识别）
}
@end

@implementation EnemyMemoryReader

+ (instancetype)sharedReader {
    static EnemyMemoryReader *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[EnemyMemoryReader alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.aimassist.memread", DISPATCH_QUEUE_SERIAL);
        _running = NO;
        _unity = NO;
    }
    return self;
}

- (BOOL)isUnityAvailable { return _unity; }

// ═══════════════════════════════════════════════════════════════════════════
//  探测 il2cpp + 缓存 Unity 类/方法
// ═══════════════════════════════════════════════════════════════════════════
- (BOOL)probeUnity {
#define AA_DLSYM(name, var) \
    var = (name##_t)dlsym(RTLD_DEFAULT, #name); \
    if (!var) { fprintf(stderr, "[AimAssist] mem: missing %s\n", #name); return NO; }

    AA_DLSYM(il2cpp_domain_get, g_domain_get);
    AA_DLSYM(il2cpp_domain_get_assemblies, g_domain_get_assemblies);
    AA_DLSYM(il2cpp_assembly_get_image, g_assembly_get_image);
    AA_DLSYM(il2cpp_image_get_name, g_image_get_name);
    AA_DLSYM(il2cpp_class_from_name, g_class_from_name);
    AA_DLSYM(il2cpp_class_get_method_from_name, g_method_from_name);
    AA_DLSYM(il2cpp_runtime_invoke, g_runtime_invoke);
    AA_DLSYM(il2cpp_string_new, g_string_new);
    AA_DLSYM(il2cpp_array_length, g_array_length);
    AA_DLSYM(il2cpp_string_chars, g_string_chars);
    AA_DLSYM(il2cpp_string_length, g_string_length);
#undef AA_DLSYM

    // 找 UnityEngine CoreModule image
    void *domain = g_domain_get();
    if (!domain) return NO;
    size_t n = 0;
    void **assems = g_domain_get_assemblies(domain, &n);
    void *unityImage = NULL;
    for (size_t i = 0; i < n; i++) {
        void *img = g_assembly_get_image(assems[i]);
        const char *nm = g_image_get_name(img);
        if (!nm) continue;
        if (strstr(nm, "UnityEngine") && strstr(nm, "CoreModule")) { unityImage = img; break; }
    }
    if (!unityImage) {
        // 兜底：遍历所有 image 找含 GameObject 类的
        for (size_t i = 0; i < n; i++) {
            void *img = g_assembly_get_image(assems[i]);
            if (g_class_from_name(img, "UnityEngine", "GameObject")) { unityImage = img; break; }
        }
    }
    if (!unityImage) { fprintf(stderr, "[AimAssist] mem: no Unity image\n"); return NO; }

    _gameObjectClass = g_class_from_name(unityImage, "UnityEngine", "GameObject");
    _transformClass  = g_class_from_name(unityImage, "UnityEngine", "Transform");
    _cameraClass     = g_class_from_name(unityImage, "UnityEngine", "Camera");
    if (!_gameObjectClass || !_transformClass || !_cameraClass) return NO;

    _mFindByTag    = g_method_from_name(_gameObjectClass, "FindGameObjectsWithTag", 1);
    _mGetTransform = g_method_from_name(_gameObjectClass, "get_transform", 0);
    _mGetName      = g_method_from_name(_gameObjectClass, "get_name", 0);
    _mGetPosition  = g_method_from_name(_transformClass, "get_position", 0);
    _mGetMain      = g_method_from_name(_cameraClass, "get_main", 0);
    _mGetWTC       = g_method_from_name(_cameraClass, "get_worldToCameraMatrix", 0);
    _mGetProj      = g_method_from_name(_cameraClass, "get_projectionMatrix", 0);
    if (!_mFindByTag || !_mGetTransform || !_mGetName || !_mGetPosition) {
        fprintf(stderr, "[AimAssist] mem: missing methods\n");
        return NO;
    }
    return YES;
}

// ═══════════════════════════════════════════════════════════════════════════
//  相机矩阵：vp = projection * worldToCamera（列主序）
// ═══════════════════════════════════════════════════════════════════════════
- (BOOL)refreshCameraMatrix {
    if (!_mGetMain || !_mGetWTC || !_mGetProj) return NO;
    void *cam = g_runtime_invoke(_mGetMain, NULL, NULL, NULL);
    if (!cam) return NO;
    void *wtcBox = g_runtime_invoke(_mGetWTC, cam, NULL, NULL);
    void *projBox = g_runtime_invoke(_mGetProj, cam, NULL, NULL);
    if (!wtcBox || !projBox) return NO;
    const float *V = AA_boxedFloats(wtcBox);
    const float *P = AA_boxedFloats(projBox);
    for (int c = 0; c < 4; c++)
        for (int r = 0; r < 4; r++) {
            float s = 0.0f;
            for (int k = 0; k < 4; k++) s += P[k * 4 + r] * V[c * 4 + k];
            _vp[c * 4 + r] = s;
        }
    return YES;
}

// 世界坐标 → 屏幕坐标（Unity: clip = vp * world）
- (BOOL)worldToScreenX:(float)x y:(float)y z:(float)z out:(CGPoint *)pt {
    float cx = _vp[0]*x + _vp[4]*y + _vp[8]*z + _vp[12];
    float cy = _vp[1]*x + _vp[5]*y + _vp[9]*z + _vp[13];
    float cz = _vp[2]*x + _vp[6]*y + _vp[10]*z + _vp[14];
    float cw = _vp[3]*x + _vp[7]*y + _vp[11]*z + _vp[15];
    if (cw <= 1e-6f || cz > cw) return NO; // 相机后方 / 远平面外
    float nx = cx / cw, ny = cy / cw;
    CGSize ss = [UIScreen mainScreen].bounds.size;
    pt->x = (nx * 0.5f + 0.5f) * ss.width;
    pt->y = (1.0f - (ny * 0.5f + 0.5f)) * ss.height;
    return YES;
}

// ═══════════════════════════════════════════════════════════════════════════
//  读取敌人：tag 查找 → 名称过滤 → 世界坐标投影 → ESPPlayerData
//  任一环节失败返回 nil（调用方回退屏幕识别）
// ═══════════════════════════════════════════════════════════════════════════
- (NSArray<ESPPlayerData *> *)readEnemies {
    if (!_unity || !_mFindByTag) return nil;
    if (![self refreshCameraMatrix]) return nil;
    CGSize ss = [UIScreen mainScreen].bounds.size;

    NSMutableArray *out = [NSMutableArray array];
    for (int t = 0; t < kEnemyTagCount && out.count < 8; t++) {
        void *tagStr = g_string_new(kEnemyTags[t]);
        void *params[1] = { tagStr };
        void *arr = g_runtime_invoke(_mFindByTag, NULL, params, NULL);
        if (!arr) continue;
        size_t len = g_array_length ? g_array_length(arr) : 0;
        if (len == 0 || len > 64) continue; // 上限防异常数据
        void **items = (void **)((char *)arr + 32); // Il2CppArray: 头16 + bounds8 + maxLength8
        for (size_t i = 0; i < len && out.count < 8; i++) {
            void *go = items[i];
            if (!go) continue;

            // 名称过滤：排除友军/玩家（tag 命中但名字明显友方的跳过）
            if (_mGetName && g_string_chars && g_string_length) {
                void *nameStr = g_runtime_invoke(_mGetName, go, NULL, NULL);
                if (nameStr) {
                    int ln = g_string_length(nameStr);
                    if (ln > 0 && ln < 64) {
                        const uint16_t *ch = g_string_chars(nameStr);
                        char buf[128]; int bl = 0;
                        for (int j = 0; j < ln && bl < 120; j++) buf[bl++] = (char)ch[j];
                        buf[bl] = 0;
                        BOOL skip = NO;
                        for (int e = 0; e < kExcludeNameCount; e++)
                            if (strcasestr(buf, kExcludeNames[e])) { skip = YES; break; }
                        if (skip) continue;
                    }
                }
            }

            // Transform 世界坐标
            void *tr = g_runtime_invoke(_mGetTransform, go, NULL, NULL);
            if (!tr) continue;
            void *posBox = g_runtime_invoke(_mGetPosition, tr, NULL, NULL);
            if (!posBox) continue;
            float *v = AA_boxedFloats(posBox);

            // 脚底 + 头顶（人体 ~1.7m）投影
            CGPoint feet, head;
            if (![self worldToScreenX:v[0] y:v[1] z:v[2] out:&feet]) continue;
            if (![self worldToScreenX:v[0] y:v[1] + 1.7f z:v[2] out:&head]) continue;

            float boxH = fabs(head.y - feet.y);
            if (boxH < ss.height * 0.03f || boxH > ss.height * 1.2f) continue;
            float boxW = boxH * 0.45f;
            CGPoint center = CGPointMake((head.x + feet.x) * 0.5f, (head.y + feet.y) * 0.5f);

            ESPPlayerData *p = [[ESPPlayerData alloc] init];
            p.isValid = YES;
            p.isEnemy = YES;
            p.health = 1.0f;
            p.screenPos = center;
            p.hasBones = YES;
            CGFloat topY = MIN(head.y, feet.y);
            p.boxRect = CGRectMake(center.x - boxW * 0.5f, topY, boxW, boxH);
            p->bonePositions[ESPBoneHead]   = head;
            p->bonePositions[ESPBoneNeck]   = CGPointMake(head.x, head.y + boxH * 0.08f);
            p->bonePositions[ESPBoneChest]  = CGPointMake(center.x, topY + boxH * 0.22f);
            p->bonePositions[ESPBonePelvis] = CGPointMake(center.x, topY + boxH * 0.48f);
            p->bonePositions[ESPBoneLThigh] = CGPointMake(center.x - boxW * 0.18f, topY + boxH * 0.55f);
            p->bonePositions[ESPBoneLShin]  = CGPointMake(center.x - boxW * 0.15f, topY + boxH * 0.75f);
            p->bonePositions[ESPBoneLFoot]  = CGPointMake(center.x - boxW * 0.18f, topY + boxH * 0.95f);
            p->bonePositions[ESPBoneRThigh] = CGPointMake(center.x + boxW * 0.18f, topY + boxH * 0.55f);
            p->bonePositions[ESPBoneRShin]  = CGPointMake(center.x + boxW * 0.15f, topY + boxH * 0.75f);
            p->bonePositions[ESPBoneRFoot]  = CGPointMake(center.x + boxW * 0.18f, topY + boxH * 0.95f);
            p->bonePositions[ESPBoneLUpperArm] = CGPointMake(center.x - boxW * 0.5f, topY + boxH * 0.25f);
            p->bonePositions[ESPBoneLForearm]  = CGPointMake(center.x - boxW * 0.55f, topY + boxH * 0.42f);
            p->bonePositions[ESPBoneLHand]     = CGPointMake(center.x - boxW * 0.5f, topY + boxH * 0.55f);
            p->bonePositions[ESPBoneRUpperArm] = CGPointMake(center.x + boxW * 0.5f, topY + boxH * 0.25f);
            p->bonePositions[ESPBoneRForearm]  = CGPointMake(center.x + boxW * 0.55f, topY + boxH * 0.42f);
            p->bonePositions[ESPBoneRHand]     = CGPointMake(center.x + boxW * 0.5f, topY + boxH * 0.55f);
            p.name = [NSString stringWithFormat:@"M%d", (int)out.count + 1];
            [out addObject:p];
        }
    }
    return out;
}

// ═══════════════════════════════════════════════════════════════════════════
//  10Hz 后台轮询
// ═══════════════════════════════════════════════════════════════════════════
- (void)tick {
    @autoreleasepool {
        NSArray *players = [self readEnemies];
        ESPManager *esp = [ESPManager sharedManager];
        if (players.count > 0) {
            [esp updatePlayers:players];
            [esp setMemoryActive:YES];
            [esp setDataSource:@"内存模型"];
            _emptyCount = 0;
        } else {
            if (++_emptyCount >= 3) { // 连续 3 帧无内存敌人 → 让位屏幕识别
                [esp setMemoryActive:NO];
            }
        }
    }
}

- (void)start {
    if (_running) return;
    _running = YES;
    dispatch_async(_queue, ^{
        _unity = [self probeUnity];
        fprintf(stderr, "[AimAssist] memory enemy reader: %s\n",
                _unity ? "Unity IL2CPP available" : "unavailable -> screen scan fallback");
        while (_running) {
            [self tick];
            usleep(100000); // 10Hz（后台串行队列，阻塞无妨）
        }
    });
}

- (void)stop {
    _running = NO;
}

@end
