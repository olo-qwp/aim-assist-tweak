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
typedef void *(*il2cpp_class_get_type_t)(void *);
typedef void *(*il2cpp_type_get_object_t)(void *);

static il2cpp_domain_get_t             g_domain_get;
static il2cpp_domain_get_assemblies_t  g_domain_get_assemblies;
static il2cpp_assembly_get_image_t     g_assembly_get_image;
static il2cpp_image_get_name_t         g_image_get_name;
static il2cpp_class_from_name_t        g_class_from_name;
static il2cpp_class_get_method_from_name_t g_method_from_name;
static il2cpp_runtime_invoke_t         g_runtime_invoke;
static il2cpp_string_new_t             g_string_new;
static il2cpp_array_length_t           g_array_length;
static il2cpp_string_chars_t           g_string_chars;
static il2cpp_string_length_t          g_string_length;
static il2cpp_class_get_type_t         g_class_get_type;
static il2cpp_type_get_object_t        g_type_get_object;

// ── 敌人 tag 列表（FPS/动作游戏通用敌人标签） ──
static const char *kEnemyTags[] = {
    "Enemy", "Zombie", "Bot", "AI", "Monster", "Minion",
    "Target", "Guard", "Soldier", "Bandit", "Drone", "Mob"
};
static const int kEnemyTagCount = 12;

// ── 名称排除词（避免把友军/自己/环境当敌人） ──
static const char *kExcludeNames[] = {
    "Player", "Ally", "Friend", "Team", "Friendly", "Hero", "Character",
    "Camera", "Light", "Terrain", "Water", "Environment", "Building",
    "Wall", "Floor", "Ground", "Tree", "Rock", "Door", "Canvas", "UI",
    "PostProcess", "Skybox", "Audio", "EventSystem", "Vehicle"
};
static const int kExcludeNameCount = 28;

// ── 路径B：组件类型查找（敌人几乎都有角色控制器/胶囊碰撞体） ──
static const char *kComponentTypes[] = {
    "CharacterController", "CapsuleCollider", "Collider"
};
static const int kComponentTypeCount = 3;

// ── 路径B：常见敌人脚本组件（Assembly-CSharp 里探测，命中即敌人） ──
static const char *kEnemyScriptTypes[] = {
    "Health", "EnemyHealth", "EnemyAI", "EnemyController", "Zombie",
    "Mob", "Monster", "Enemy", "NPC", "Guard"
};
static const int kEnemyScriptTypeCount = 10;

// ── 抛过异常的 tag/类型（Unity 未定义 tag 或组件类不存在时每次调用都抛
//    托管异常，捕获一次后永久跳过，避免每 tick 异常开销） ──
static BOOL g_badTag[kEnemyTagCount];
static BOOL g_badComponent[kComponentTypeCount];
static BOOL g_badScript[kEnemyScriptTypeCount];
static BOOL g_badScenePath;   // 场景遍历路径整体失败（无 SceneManager API 等）

// ═══════════════════════════════════════════════════════════════════════════
//  Cocos2d-x 内存路径（无偏移）—— dlsym 引擎导出符号 + 场景树遍历
//  覆盖非 Unity 手游（cocos2d-x 3.x 导出符号稳定）
//  mangled 符号：cocos2d::Director::getInstance / getRunningScene /
//  Node::getWorldPosition / getContentSize / getChildren / Director::getWinSize
// ═══════════════════════════════════════════════════════════════════════════
static void *(*cocos_Director_getInstance)(void);
static void *(*cocos_Director_getRunningScene)(void *);
static uint64_t (*cocos_Node_getWorldPosition)(void *);   // Vec2 挤在低 64 位
static uint64_t (*cocos_Node_getContentSize)(void *);     // Size 同
static void *(*cocos_Node_getChildren)(void *);           // const Vector<Node*>&
static uint64_t (*cocos_Director_getWinSize)(void *);
static BOOL g_cocos = NO;

// ── arm64: Il2CppObject 头 16 字节(klass+monitor)，boxed struct 数据从 16 开始 ──
static float *AA_boxedFloats(void *boxed) { return (float *)((char *)boxed + 16); }

// ── 世界坐标去重（同一敌人可能被多条路径命中） ──
typedef struct { float x, y, z; } AA_WPos;

@interface EnemyMemoryReader () {
    NSTimer *_timer;           // 主线程 10Hz 轮询（Unity API 要求主线程）
    BOOL _unity;

    // 缓存的 Unity 类/方法句柄
    void *_gameObjectClass;
    void *_transformClass;
    void *_cameraClass;
    void *_componentClass;     // UnityEngine.Component
    void *_objectClass;        // UnityEngine.Object
    void *_sceneClass;         // UnityEngine.SceneManagement.Scene
    void *_sceneManagerClass;  // UnityEngine.SceneManagement.SceneManager
    void *_mFindByTag;     // GameObject.FindGameObjectsWithTag(string)
    void *_mFindOfType;    // Object.FindObjectsOfType(System.Type) [static]
    void *_mGetTransform;  // GameObject.get_transform
    void *_mGetName;       // GameObject.get_name
    void *_mGetPosition;   // Transform.get_position
    void *_mGetMain;       // Camera.get_main (static)
    void *_mGetWTC;        // Camera.get_worldToCameraMatrix
    void *_mGetProj;       // Camera.get_projectionMatrix
    void *_mCompGameObj;   // Component.get_gameObject
    void *_mGetActiveScene;// SceneManager.GetActiveScene (static)
    void *_mGetRootGO;     // Scene.GetRootGameObjects
    void *_mGetChildCount; // Transform.GetChildCount
    void *_mGetChild;      // Transform.GetChild(int)

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
        _unity = NO;
    }
    return self;
}

- (BOOL)isUnityAvailable { return _unity; }

// ═══════════════════════════════════════════════════════════════════════════
//  Cocos2d-x 探测 — dlsym 引擎导出符号（无偏移）
// ═══════════════════════════════════════════════════════════════════════════
- (BOOL)probeCocos {
#define COCOS_SYM(var, mangled) \
    var = (__typeof__(var))dlsym(RTLD_DEFAULT, mangled); \
    if (!var) return NO;

    COCOS_SYM(cocos_Director_getInstance, "_ZN7cocos2d8Director11getInstanceEv");
    COCOS_SYM(cocos_Director_getRunningScene, "_ZN7cocos2d8Director16getRunningSceneEv");
    COCOS_SYM(cocos_Node_getWorldPosition, "_ZNK7cocos2d4Node16getWorldPositionEv");
    COCOS_SYM(cocos_Node_getContentSize, "_ZNK7cocos2d4Node14getContentSizeEv");
    COCOS_SYM(cocos_Node_getChildren, "_ZNK7cocos2d4Node11getChildrenEv");
    COCOS_SYM(cocos_Director_getWinSize, "_ZNK7cocos2d8Director10getWinSizeEv");
#undef COCOS_SYM
    return YES;
}

- (BOOL)cocosAvailable { return g_cocos; }

// Cocos Vector<Node*> 内存布局（libc++ std::vector 包装）：
//   [0]=begin指针 [8]=end [16]=end_of_storage；size=(end-begin)/8
static void **cocosVectorData(void *v) { return *(void ***)v; }
static size_t cocosVectorSize(void *v) {
    return (((size_t *)v)[1] - ((size_t *)v)[0]) >> 3;
}

// ═══════════════════════════════════════════════════════════════════════════
//  Cocos 树遍历 + 锚点匹配：
//  在运行场景的节点树中找离锚点（选中模型屏幕位置）最近的合理尺寸节点，
//  用其世界坐标驱动自瞄——完全内存、无偏移、稳定。
//  (ponytail: 每帧全树遍历（预算 400 节点），不持有节点指针跨帧，
//   节点销毁自动落到次近节点，无野指针风险)
// ═══════════════════════════════════════════════════════════════════════════
- (BOOL)trackCocosModelNear:(CGPoint)anchor outPos:(CGPoint *)outPos outSize:(float *)outSize {
    if (!g_cocos || !cocos_Director_getRunningScene || !cocos_Node_getChildren ||
        !cocos_Node_getWorldPosition || !cocos_Node_getContentSize || !cocos_Director_getWinSize)
        return NO;

    void *dir = cocos_Director_getInstance();
    if (!dir) return NO;
    void *scene = cocos_Director_getRunningScene(dir);
    if (!scene) return NO;
    uint64_t ws = cocos_Director_getWinSize(dir);
    float designW = (float)(ws & 0xffffffffu);
    float designH = (float)(ws >> 32);
    if (designW < 1 || designH < 1) return NO;

    CGSize ss = [UIScreen mainScreen].bounds.size;
    float scale = MIN(ss.width / designW, ss.height / designH);
    if (scale <= 0) return NO;

    // 迭代式 DFS（C 栈，避免 block 递归的 retain cycle）
    __block float bestD = 1e18f;
    __block float bestX = 0, bestY = 0, bestSz = 0;
    __block BOOL found = NO;
    __block int budget = 400;

    void **stack = (void **)malloc(1024 * sizeof(void *));
    if (!stack) return NO;
    int sp = 0;
    stack[sp++] = scene;
    while (sp > 0 && budget > 0) {
        void *node = stack[--sp];
        if (!node) continue;
        budget--;

        uint64_t wv = cocos_Node_getWorldPosition(node);
        float wx = (float)(wv & 0xffffffffu);
        float wy = (float)(wv >> 32);
        uint64_t cs = cocos_Node_getContentSize(node);
        float cw = (float)(cs & 0xffffffffu);
        float ch = (float)(cs >> 32);

        // 尺寸过滤：节点要有合理大小（设计单位），排除零尺寸空节点/巨大背景
        if (cw >= 10.0f && ch >= 10.0f && cw < designW * 0.5f && ch < designH * 0.5f) {
            // 世界坐标（原点左下）→ 屏幕坐标
            float sx = (wx - designW * 0.5f) * scale + ss.width * 0.5f;
            float sy = (wy - designH * 0.5f) * scale + ss.height * 0.5f;
            if (sx > -50 && sx < ss.width + 50 && sy > -50 && sy < ss.height + 50) {
                float d = (sx - anchor.x) * (sx - anchor.x) + (sy - anchor.y) * (sy - anchor.y);
                if (d < bestD) {
                    bestD = d;
                    bestX = sx; bestY = sy;
                    bestSz = (cw + ch) * 0.5f * scale;
                    found = YES;
                }
            }
        }

        void *children = cocos_Node_getChildren(node);
        if (children) {
            void **items = cocosVectorData(children);
            size_t n = cocosVectorSize(children);
            for (size_t i = 0; i < n && sp < 1024; i++) {
                if (items[i]) stack[sp++] = items[i];
            }
        }
    }
    free(stack);

    if (!found) return NO;
    if (outPos) *outPos = CGPointMake(bestX, bestY);
    if (outSize) *outSize = bestSz;
    return YES;
}

// ═══════════════════════════════════════════════════════════════════════════
//  探测 il2cpp + 缓存 Unity 类/方法（纯元数据查询，无托管调用）
// ═══════════════════════════════════════════════════════════════════════════
- (BOOL)probeUnity {
#define AA_DLSYM(name, var) \
    var = (name##_t)dlsym(RTLD_DEFAULT, #name); \
    if (!var) return NO;

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
    // 类型路径 API 非必需：缺失则仅用 tag 路径
    g_class_get_type  = (il2cpp_class_get_type_t)dlsym(RTLD_DEFAULT, "il2cpp_class_get_type");
    g_type_get_object = (il2cpp_type_get_object_t)dlsym(RTLD_DEFAULT, "il2cpp_type_get_object");
#undef AA_DLSYM

    // 找 UnityEngine.CoreModule image
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
        for (size_t i = 0; i < n; i++) {
            void *img = g_assembly_get_image(assems[i]);
            if (g_class_from_name(img, "UnityEngine", "GameObject")) { unityImage = img; break; }
        }
    }
    if (!unityImage) return NO;

    _gameObjectClass = g_class_from_name(unityImage, "UnityEngine", "GameObject");
    _transformClass  = g_class_from_name(unityImage, "UnityEngine", "Transform");
    _cameraClass     = g_class_from_name(unityImage, "UnityEngine", "Camera");
    _componentClass  = g_class_from_name(unityImage, "UnityEngine", "Component");
    _objectClass     = g_class_from_name(unityImage, "UnityEngine", "Object");
    _sceneClass      = g_class_from_name(unityImage, "UnityEngine", "Scene");
    _sceneManagerClass = g_class_from_name(unityImage, "UnityEngine", "SceneManager");
    if (!_gameObjectClass || !_transformClass || !_cameraClass) return NO;

    _mFindByTag    = g_method_from_name(_gameObjectClass, "FindGameObjectsWithTag", 1);
    _mGetTransform = g_method_from_name(_gameObjectClass, "get_transform", 0);
    _mGetName      = g_method_from_name(_gameObjectClass, "get_name", 0);
    _mGetPosition  = g_method_from_name(_transformClass, "get_position", 0);
    _mGetMain      = g_method_from_name(_cameraClass, "get_main", 0);
    _mGetWTC       = g_method_from_name(_cameraClass, "get_worldToCameraMatrix", 0);
    _mGetProj      = g_method_from_name(_cameraClass, "get_projectionMatrix", 0);
    if (!_mFindByTag || !_mGetTransform || !_mGetName || !_mGetPosition) return NO;

    // 路径B/C 可选方法（缺失则对应路径自动禁用）
    if (_componentClass)  _mCompGameObj   = g_method_from_name(_componentClass, "get_gameObject", 0);
    if (_objectClass && g_class_get_type && g_type_get_object)
        _mFindOfType = g_method_from_name(_objectClass, "FindObjectsOfType", 1);
    if (_sceneManagerClass) _mGetActiveScene = g_method_from_name(_sceneManagerClass, "GetActiveScene", 0);
    if (_sceneClass) _mGetRootGO = g_method_from_name(_sceneClass, "GetRootGameObjects", 0);
    _mGetChildCount = g_method_from_name(_transformClass, "GetChildCount", 0);
    _mGetChild      = g_method_from_name(_transformClass, "GetChild", 1);
    return YES;
}

// ═══════════════════════════════════════════════════════════════════════════
//  相机矩阵：vp = projection * worldToCamera（列主序）
//  ⚠️ 所有 runtime_invoke 必须传异常输出参数——IL2CPP 遇到托管异常
//     且无接收者时会直接 abort 进程（闪退根因）
// ═══════════════════════════════════════════════════════════════════════════
- (BOOL)refreshCameraMatrix {
    if (!_mGetMain || !_mGetWTC || !_mGetProj) return NO;
    void *exc = NULL;
    void *cam = g_runtime_invoke(_mGetMain, NULL, NULL, &exc);
    if (exc || !cam) return NO;

    exc = NULL;
    void *wtcBox = g_runtime_invoke(_mGetWTC, cam, NULL, &exc);
    if (exc || !wtcBox) return NO;

    exc = NULL;
    void *projBox = g_runtime_invoke(_mGetProj, cam, NULL, &exc);
    if (exc || !projBox) return NO;

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

- (BOOL)worldToScreenX:(float)x y:(float)y z:(float)z out:(CGPoint *)pt {
    float cx = _vp[0]*x + _vp[4]*y + _vp[8]*z + _vp[12];
    float cy = _vp[1]*x + _vp[5]*y + _vp[9]*z + _vp[13];
    float cz = _vp[2]*x + _vp[6]*y + _vp[10]*z + _vp[14];
    float cw = _vp[3]*x + _vp[7]*y + _vp[11]*z + _vp[15];
    if (cw <= 1e-6f || cz > cw) return NO;
    float nx = cx / cw, ny = cy / cw;
    CGSize ss = [UIScreen mainScreen].bounds.size;
    pt->x = (nx * 0.5f + 0.5f) * ss.width;
    pt->y = (1.0f - (ny * 0.5f + 0.5f)) * ss.height;
    return YES;
}

// ═══════════════════════════════════════════════════════════════════════════
//  名称过滤：排除友军/玩家/环境对象
// ═══════════════════════════════════════════════════════════════════════════
- (BOOL)nameIsExcluded:(void *)go {
    if (!_mGetName || !g_string_chars || !g_string_length) return NO;
    void *exc = NULL;
    void *nameStr = g_runtime_invoke(_mGetName, go, NULL, &exc);
    if (exc) return YES; // 对象已销毁
    if (!nameStr) return NO;
    int ln = g_string_length(nameStr);
    if (ln <= 0 || ln >= 64) return NO;
    const uint16_t *ch = g_string_chars(nameStr);
    char buf[128]; int bl = 0;
    for (int j = 0; j < ln && bl < 120; j++) buf[bl++] = (char)ch[j];
    buf[bl] = 0;
    for (int e = 0; e < kExcludeNameCount; e++)
        if (strcasestr(buf, kExcludeNames[e])) return YES;
    return NO;
}

// ═══════════════════════════════════════════════════════════════════════════
//  由 GameObject 生成 ESPPlayerData（世界坐标投影 + 骨骼点）
//  返回 nil 表示不可见/尺寸异常
// ═══════════════════════════════════════════════════════════════════════════
- (ESPPlayerData *)makePlayerFromGameObject:(void *)go
                                      world:(AA_WPos)w
                                     outIdx:(int)idx {
    CGSize ss = [UIScreen mainScreen].bounds.size;
    CGPoint feet, head;
    if (![self worldToScreenX:w.x y:w.y z:w.z out:&feet]) return nil;
    if (![self worldToScreenX:w.x y:w.y + 1.7f z:w.z out:&head]) return nil;

    float boxH = fabs(head.y - feet.y);
    if (boxH < ss.height * 0.03f || boxH > ss.height * 1.2f) return nil;
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
    p.name = [NSString stringWithFormat:@"M%d", idx];
    return p;
}

// 读 GameObject 世界坐标；失败返回 NO
- (BOOL)worldPosOfGameObject:(void *)go out:(AA_WPos *)w {
    void *exc = NULL;
    void *tr = g_runtime_invoke(_mGetTransform, go, NULL, &exc);
    if (exc || !tr) return NO;
    exc = NULL;
    void *posBox = g_runtime_invoke(_mGetPosition, tr, NULL, &exc);
    if (exc || !posBox) return NO;
    float *v = AA_boxedFloats(posBox);
    w->x = v[0]; w->y = v[1]; w->z = v[2];
    return YES;
}

// 世界坐标去重：与已有结果距离 <3m 视为同一对象
- (BOOL)isDuplicate:(AA_WPos)w in:(NSArray *)seen {
    for (NSValue *v in seen) {
        AA_WPos o; [v getValue:&o];
        float dx = w.x - o.x, dy = w.y - o.y, dz = w.z - o.z;
        if (dx*dx + dy*dy + dz*dz < 9.0f) return YES; // 3m
    }
    return NO;
}

// ═══════════════════════════════════════════════════════════════════════════
//  路径A：tag 查找（Enemy/Zombie/... 12 种）
// ═══════════════════════════════════════════════════════════════════════════
- (void)scanByTags:(NSMutableArray *)out seen:(NSMutableArray *)seen {
    if (!_mFindByTag) return;
    for (int t = 0; t < kEnemyTagCount && out.count < 8; t++) {
        if (g_badTag[t]) continue;
        void *tagStr = g_string_new(kEnemyTags[t]);
        void *params[1] = { tagStr };
        void *exc = NULL;
        void *arr = g_runtime_invoke(_mFindByTag, NULL, params, &exc);
        if (exc) { g_badTag[t] = YES; continue; }
        if (!arr) continue;
        size_t len = g_array_length ? g_array_length(arr) : 0;
        if (len == 0 || len > 64) continue;
        void **items = (void **)((char *)arr + 32);
        for (size_t i = 0; i < len && out.count < 8; i++) {
            void *go = items[i];
            if (!go || [self nameIsExcluded:go]) continue;
            AA_WPos w;
            if (![self worldPosOfGameObject:go out:&w]) continue;
            if ([self isDuplicate:w in:seen]) continue;
            ESPPlayerData *p = [self makePlayerFromGameObject:go world:w outIdx:(int)out.count + 1];
            if (p) { [out addObject:p]; [seen addObject:[NSValue valueWithBytes:&w objCType:@encode(AA_WPos)]]; }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  路径B：组件类型查找（CharacterController/CapsuleCollider/Collider +
//  常见敌人脚本），不依赖 tag——很多游戏敌人没有 Enemy tag 但有角色组件
// ═══════════════════════════════════════════════════════════════════════════
- (void)scanByComponents:(NSMutableArray *)out seen:(NSMutableArray *)seen {
    if (!_mFindOfType || !_mCompGameObj) return;

    // B1: 引擎组件类（CoreModule）
    for (int c = 0; c < kComponentTypeCount && out.count < 8; c++) {
        if (g_badComponent[c]) continue;
        void *cls = g_class_from_name(NULL, "UnityEngine", kComponentTypes[c]);
        if (!cls) { g_badComponent[c] = YES; continue; }
        [self scanByClass:cls badFlag:&g_badComponent[c] out:out seen:seen];
    }

    // B2: 常见敌人脚本组件（Assembly-CSharp）
    if (out.count >= 8) return;
    void *domain = g_domain_get();
    size_t n = 0;
    void **assems = g_domain_get_assemblies(domain, &n);
    for (int c = 0; c < kEnemyScriptTypeCount && out.count < 8; c++) {
        if (g_badScript[c]) continue;
        void *cls = NULL;
        for (size_t i = 0; i < n && !cls; i++) {
            void *img = g_assembly_get_image(assems[i]);
            cls = g_class_from_name(img, "", kEnemyScriptTypes[c]);
        }
        if (!cls) { g_badScript[c] = YES; continue; }
        [self scanByClass:cls badFlag:&g_badScript[c] out:out seen:seen];
    }
}

// 用单个类执行 FindObjectsOfType 并收集
- (void)scanByClass:(void *)cls badFlag:(BOOL *)bad out:(NSMutableArray *)out seen:(NSMutableArray *)seen {
    void *type = g_class_get_type(cls);
    if (!type) { *bad = YES; return; }
    void *typeObj = g_type_get_object(type);
    if (!typeObj) { *bad = YES; return; }
    void *params[1] = { typeObj };
    void *exc = NULL;
    void *arr = g_runtime_invoke(_mFindOfType, NULL, params, &exc);
    if (exc) { *bad = YES; return; }
    if (!arr) return;
    size_t len = g_array_length ? g_array_length(arr) : 0;
    if (len == 0 || len > 256) return;
    void **items = (void **)((char *)arr + 32);
    for (size_t i = 0; i < len && out.count < 8; i++) {
        void *comp = items[i];
        if (!comp) continue;
        exc = NULL;
        void *go = g_runtime_invoke(_mCompGameObj, comp, NULL, &exc);
        if (exc || !go) continue;
        if ([self nameIsExcluded:go]) continue;
        AA_WPos w;
        if (![self worldPosOfGameObject:go out:&w]) continue;
        if ([self isDuplicate:w in:seen]) continue;
        ESPPlayerData *p = [self makePlayerFromGameObject:go world:w outIdx:(int)out.count + 1];
        if (p) { [out addObject:p]; [seen addObject:[NSValue valueWithBytes:&w objCType:@encode(AA_WPos)]]; }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  路径C：场景根对象遍历（完全不依赖 tag/组件约定，兜底）
//  递归 transform 树，名称过滤 + 高度验证
//  (ponytail: 每帧限制 200 个节点防性能问题；深度 ≤6)
// ═══════════════════════════════════════════════════════════════════════════
- (void)scanSceneTree:(NSMutableArray *)out seen:(NSMutableArray *)seen {
    if (g_badScenePath || !_mGetActiveScene || !_mGetRootGO || !_mGetChildCount || !_mGetChild)
        return;
    void *exc = NULL;
    void *sceneBox = g_runtime_invoke(_mGetActiveScene, NULL, NULL, &exc);
    if (exc || !sceneBox) { g_badScenePath = YES; return; }
    exc = NULL;
    void *arr = g_runtime_invoke(_mGetRootGO, sceneBox, NULL, &exc);
    if (exc || !arr) { g_badScenePath = YES; return; }
    size_t len = g_array_length ? g_array_length(arr) : 0;
    if (len > 128) return;
    void **items = (void **)((char *)arr + 32);
    int budget = 200;

    for (size_t i = 0; i < len && out.count < 8; i++) {
        void *go = items[i];
        if (!go || [self nameIsExcluded:go]) continue;
        budget -= [self walkTransformTree:go depth:0 budget:&budget out:out seen:seen];
        if (budget <= 0) break;
    }
}

- (int)walkTransformTree:(void *)go depth:(int)d budget:(int *)budget
                     out:(NSMutableArray *)out seen:(NSMutableArray *)seen {
    if (*budget <= 0 || out.count >= 8) return 0;
    int visited = 1;
    (*budget)--;
    if (d <= 2) { // 只在浅层节点做位置收集（深层多为子部件/装饰）
        AA_WPos w;
        if (![self nameIsExcluded:go] &&
            [self worldPosOfGameObject:go out:&w] &&
            ![self isDuplicate:w in:seen]) {
            ESPPlayerData *p = [self makePlayerFromGameObject:go world:w outIdx:(int)out.count + 1];
            if (p) { [out addObject:p]; [seen addObject:[NSValue valueWithBytes:&w objCType:@encode(AA_WPos)]]; }
        }
    }
    if (d >= 6 || *budget <= 0 || out.count >= 8) return visited;
    void *exc = NULL;
    void *tr = g_runtime_invoke(_mGetTransform, go, NULL, &exc);
    if (exc || !tr) return visited;
    exc = NULL;
    void *cntBox = g_runtime_invoke(_mGetChildCount, tr, NULL, &exc);
    if (exc) return visited;
    int n = cntBox ? *(int *)AA_boxedFloats(cntBox) : 0;
    if (n < 0 || n > 32) n = 0;
    for (int i = 0; i < n && *budget > 0 && out.count < 8; i++) {
        void *p2[1] = { (void *)(intptr_t)i };
        exc = NULL;
        void *childTr = g_runtime_invoke(_mGetChild, tr, p2, &exc);
        if (exc || !childTr) continue;
        exc = NULL;
        void *childGo = g_runtime_invoke(_mCompGameObj ? _mCompGameObj : _mGetTransform, childTr, NULL, &exc);
        if (exc || !childGo) continue;
        visited += [self walkTransformTree:childGo depth:d + 1 budget:budget out:out seen:seen];
    }
    return visited;
}

// ═══════════════════════════════════════════════════════════════════════════
//  读取敌人：A(tag) → B(组件) → C(场景遍历)，世界坐标去重合并
// ═══════════════════════════════════════════════════════════════════════════
- (NSArray<ESPPlayerData *> *)readEnemies {
    if (!_unity) return nil;
    if (![self refreshCameraMatrix]) return nil;

    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *seen = [NSMutableArray array];
    [self scanByTags:out seen:seen];
    [self scanByComponents:out seen:seen];
    [self scanSceneTree:out seen:seen];
    return out;
}

// ═══════════════════════════════════════════════════════════════════════════
//  主线程 10Hz 轮询（Unity API 大多要求主线程；NSTimer 天然串行无重入）
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
    if (_timer) return;
    _unity = [self probeUnity];
    g_cocos = [self probeCocos];
    fprintf(stderr, "[AimAssist] memory reader: unity=%s cocos=%s\n",
            _unity ? "yes" : "no", g_cocos ? "yes" : "no");
    if (!_unity && !g_cocos) {
        fprintf(stderr, "[AimAssist] no engine memory path -> screen scan fallback\n");
        return;
    }
    memset(g_badTag, 0, sizeof(g_badTag));
    memset(g_badComponent, 0, sizeof(g_badComponent));
    memset(g_badScript, 0, sizeof(g_badScript));
    g_badScenePath = NO;
    _emptyCount = 0;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                              target:self
                                            selector:@selector(tick)
                                            userInfo:nil
                                             repeats:YES];
    [self tick];
}

- (void)stop {
    [_timer invalidate];
    _timer = nil;
}

@end
