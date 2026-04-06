
// QQESign — 免越狱轻松签版 (NT架构)
// 防撤回 / 闪照保存+无限查看 / 自定义设备名+电量
// Target: com.tencent.mqq (arm64) — sideload injection

%config(generator=internal)

// ═══════════════════════════════════════════════════
// 架构说明 (NT QQ)
// ═══════════════════════════════════════════════════
// QQ NT 架构已将大量逻辑迁移至 Swift，ObjC 层只保留了
// 部分 bridge 类。以下 hook 点均经过 ObjC classlist 验证，
// 确认在当前版本 QQ 二进制中实际存在。
//
// 防撤回：
//   保守稳定版：移除全局 selector 扫描与宽泛类名匹配，
//   仅保留主序中已确认存在、且 type encoding 已核对的显式 hook。
//   同时将安装时机后移，减少 ctor 阶段全局扫描导致的开屏闪退风险。
//
// 闪照：
//   OCPicElement / QQBasePhoto.isFlashPic 返回 NO 即可解除
//   所有闪照限制（倒计时、保存限制、次数限制）。
//   NT Swift VC 的 hideFlashImgPreview / finishFlashImgPreview
//   也可拦截使图片不消失。
// ═══════════════════════════════════════════════════

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

// ─────────────────────────────────────────────
#pragma mark - Preferences (sandbox-safe)
// ─────────────────────────────────────────────

static NSString *const kPrefSuite = @"com.qqesign.prefs";

static BOOL   pref_antiRevoke     = YES;
static BOOL   pref_flashUnlimited = YES;
static BOOL   pref_flashSave      = YES;
static BOOL   pref_fakeDevice     = NO;
static NSString *pref_deviceName  = @"iPhone 16 Pro";
static BOOL   pref_fakeBattery    = NO;
static float  pref_batteryLevel   = 0.80f;
static BOOL   pref_isCharging     = NO;

static NSUserDefaults *tweakDefaults(void) {
    static NSUserDefaults *ud = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefSuite];
        [ud registerDefaults:@{
            @"antiRevoke":     @YES,
            @"flashUnlimited": @YES,
            @"flashSave":      @YES,
            @"fakeDevice":     @NO,
            @"deviceName":     @"iPhone 16 Pro",
            @"fakeBattery":    @NO,
            @"batteryLevel":   @0.80f,
            @"isCharging":     @NO,
        }];
    });
    return ud;
}

static void loadPrefs(void) {
    NSUserDefaults *ud = tweakDefaults();
    pref_antiRevoke     = [ud boolForKey:@"antiRevoke"];
    pref_flashUnlimited = [ud boolForKey:@"flashUnlimited"];
    pref_flashSave      = [ud boolForKey:@"flashSave"];
    pref_fakeDevice     = [ud boolForKey:@"fakeDevice"];
    pref_fakeBattery    = [ud boolForKey:@"fakeBattery"];
    pref_batteryLevel   = [ud floatForKey:@"batteryLevel"];
    pref_isCharging     = [ud boolForKey:@"isCharging"];
    NSString *name = [ud stringForKey:@"deviceName"];
    if (name.length > 0) pref_deviceName = name;
}

// ─────────────────────────────────────────────
#pragma mark - Helpers
// ─────────────────────────────────────────────

static void saveImageToCameraRoll(UIImage *image) {
    if (!image) return;
    PHAuthorizationStatus s = [PHPhotoLibrary authorizationStatus];
    BOOL ok = (s == PHAuthorizationStatusAuthorized);
    if (@available(iOS 14.0, *)) ok = ok || (s == PHAuthorizationStatusLimited);
    if (!ok) return;
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromImage:image];
    } completionHandler:^(BOOL success, NSError *err) {
        NSLog(@"[QQESign] 闪照保存%@", success ? @"成功" : ([NSString stringWithFormat:@"失败: %@", err]));
    }];
}

static UIImage *findImageInView(UIView *root) {
    if ([root isKindOfClass:[UIImageView class]]) {
        UIImage *img = ((UIImageView *)root).image;
        if (img) return img;
    }
    for (UIView *sub in root.subviews) {
        UIImage *img = findImageInView(sub);
        if (img) return img;
    }
    return nil;
}

static UIWindow *activeForegroundWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            for (UIWindow *w in ws.windows) {
                if (!w.hidden) return w;
            }
        }
    }
    return [UIApplication sharedApplication].keyWindow;
}

// ─────────────────────────────────────────────
#pragma mark - In-App Settings UI
// ─────────────────────────────────────────────

@interface QQESignSettingsController : UITableViewController
@end

@implementation QQESignSettingsController {
    NSArray<NSArray<NSDictionary *> *> *_sections;
    NSArray<NSString *> *_sectionTitles;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"QQESign 设置";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(dismissSelf)];
    [self rebuildSections];
}

- (void)rebuildSections {
    _sectionTitles = @[@"消息防撤回", @"闪照设置", @"自定义设备名", @"自定义电量", @"关于"];
    _sections = @[
        @[@{@"title": @"开启防撤回", @"key": @"antiRevoke", @"type": @"switch"}],
        @[
            @{@"title": @"无限次查看闪照", @"key": @"flashUnlimited", @"type": @"switch"},
            @{@"title": @"自动保存闪照到相册", @"key": @"flashSave", @"type": @"switch"},
        ],
        @[
            @{@"title": @"启用自定义设备名", @"key": @"fakeDevice", @"type": @"switch"},
            @{@"title": @"设备名称", @"key": @"deviceName", @"type": @"text"},
        ],
        @[
            @{@"title": @"启用自定义电量", @"key": @"fakeBattery", @"type": @"switch"},
            @{@"title": @"电量 (0~100)", @"key": @"batteryLevel", @"type": @"number"},
            @{@"title": @"模拟充电中", @"key": @"isCharging", @"type": @"switch"},
        ],
        @[@{@"title": @"QQESign v2.0\n适配NT架构 · 防撤回 · 闪照解锁\n自定义设备名与电量", @"type": @"info"}],
    ];
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _sections.count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _sectionTitles[s]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _sections[s].count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *item = _sections[ip.section][ip.row];
    NSString *type = item[@"type"], *key = item[@"key"];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = item[@"title"];
    cell.textLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if ([type isEqualToString:@"switch"]) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [tweakDefaults() boolForKey:key];
        sw.tag = ip.section * 100 + ip.row;
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if ([type isEqualToString:@"text"]) {
        cell.detailTextLabel.text = [tweakDefaults() stringForKey:key] ?: @"";
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if ([type isEqualToString:@"number"]) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", [tweakDefaults() floatForKey:key] * 100];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *item = _sections[ip.section][ip.row];
    NSString *type = item[@"type"], *key = item[@"key"];
    if ([type isEqualToString:@"text"]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:item[@"title"] message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = [tweakDefaults() stringForKey:key];
            tf.placeholder = @"iPhone 16 Pro";
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            NSString *val = a.textFields.firstObject.text;
            if (val.length > 0) {
                [tweakDefaults() setObject:val forKey:key];
                [tweakDefaults() synchronize];
                loadPrefs();
                [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
            }
        }]];
        [self presentViewController:a animated:YES completion:nil];
    } else if ([type isEqualToString:@"number"]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:item[@"title"] message:@"输入 0~100 之间的整数" preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = [NSString stringWithFormat:@"%.0f", [tweakDefaults() floatForKey:key] * 100];
            tf.keyboardType = UIKeyboardTypeNumberPad;
            tf.placeholder = @"80";
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            float f = [a.textFields.firstObject.text floatValue] / 100.0f;
            f = MAX(0, MIN(1, f));
            [tweakDefaults() setFloat:f forKey:key];
            [tweakDefaults() synchronize];
            loadPrefs();
            [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

- (void)switchChanged:(UISwitch *)sw {
    NSDictionary *item = _sections[sw.tag / 100][sw.tag % 100];
    [tweakDefaults() setBool:sw.on forKey:item[@"key"]];
    [tweakDefaults() synchronize];
    loadPrefs();
}

@end

static void showQQESignSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = activeForegroundWindow();
        if (!win) return;
        UIViewController *root = win.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        UITableViewStyle style = UITableViewStyleGrouped;
        if (@available(iOS 13.0, *)) style = UITableViewStyleInsetGrouped;
        QQESignSettingsController *vc = [[QQESignSettingsController alloc] initWithStyle:style];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [root presentViewController:nav animated:YES completion:nil];
    });
}

static void addESignButton(UIViewController *vc, SEL action) {
    if (!vc) return;
    for (UIBarButtonItem *item in vc.navigationItem.rightBarButtonItems) {
        if ([item.title isEqualToString:@"ESign"]) return;
    }
    if ([vc.navigationItem.rightBarButtonItem.title isEqualToString:@"ESign"]) return;
    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"ESign"
                                                            style:UIBarButtonItemStylePlain
                                                           target:vc
                                                           action:action];
    NSMutableArray *items = [vc.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items addObject:btn];
    vc.navigationItem.rightBarButtonItems = items;
}


#pragma mark - 1. Anti-recall runtime hooks (NT QQ)

// 这段为折中合并版：
// 1) 采用 txt 中更准确的“普通撤回主链”判断：
//    QQMessageRecallNetEngine.parseC2CRecallNotify...
//      -> QQMessageRecallModule.convertRecallItemToMsg...
//      -> QQMessageDecouplingBridge.recallMessagePair:
//      -> NTAIOGrayTipsOtherLinkRecallHandle.grayTipsEvent...
// 2) 不再把 handleSideAccountRecallNotify... 当成“普通消息总入口”，
//    仅作为 side-account / 特殊分支保留。
// 3) 同时保留此前代码里几个已经在主程序中确认存在、且对表现层补漏有帮助的显式 hook：
//    GroupEmotionManager.recallMessagePair:
//    NTAIOChat.onReceiveRecallMsgNotification:
//    QQAIOCell.updateCellViewRecall
//    NudgeActionManager.insertRecallGrayTips2AioIfneed:isGroup:
//    以及少量 RichMedia / ChatFiles / GPro / FloatEar / Guild 分发点。
// 4) 不做全量类扫描，不做宽泛 selector 补挂。

typedef struct {
    Class cls;
    SEL sel;
    IMP orig;
} QQESignRecallHookRecord;

static QQESignRecallHookRecord gQQESignRecallHooks[48];
static NSUInteger gQQESignRecallHookCount = 0;

typedef BOOL (*QQEOrigBoolRecallNetParse)(id, SEL, const void *, int, int, void *);
typedef id   (*QQEOrigIdRecallModuleFull)(id, SEL, const void *, int, int, unsigned long long, BOOL *);
typedef id   (*QQEOrigIdRecallConvert)(id, SEL, const void *, void *, int, unsigned long long);
typedef id   (*QQEOrigIdIntBool)(id, SEL, int, BOOL);
typedef void (*QQEOrigVoidOneObj)(id, SEL, id);
typedef void (*QQEOrigVoidTwoObj)(id, SEL, id, id);
typedef void (*QQEOrigVoidThreeObj)(id, SEL, id, id, id);
typedef void (*QQEOrigVoidZeroArg)(id, SEL);
typedef BOOL (*QQEOrigBoolZeroArg)(id, SEL);
typedef BOOL (*QQEOrigBoolOneObj)(id, SEL, id);
typedef void (*QQEOrigVoidOneBool)(id, SEL, BOOL);
typedef void (*QQEOrigVoidOneObjBool)(id, SEL, id, BOOL);
typedef void (*QQEOrigVoidGrayTip)(id, SEL, id, id, id, unsigned int);
typedef void (*QQEOrigVoidMsgRecall3)(id, SEL, int, id, unsigned long long);
typedef void (*QQEOrigVoidGuildPush)(id, SEL, long long, long long, long long, int, id, id, id, id, int);

typedef struct {
    const char *className;
    const char *selName;
    const char *typeEncoding;
    IMP newImp;
    const char *tag;
} QQESignRecallMethodSpec;

static BOOL qqesignIsRecallNotificationName(NSString *name) {
    if (name.length == 0) return NO;
    static NSSet<NSString *> *exact = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exact = [NSSet setWithArray:@[
            @"__QQReceiveRecallMsgNotification__",
            @"__QQReceiveRecallForVideoStopNotification__",
            @"__QQReceiveRecallFormFileNotification__",
            @"__QQGProReceiveRecallMsgNotifications__",
        ]];
    });
    if ([exact containsObject:name]) return YES;
    if ([name hasPrefix:@"__QQReceiveRecall"] || [name hasPrefix:@"QQReceiveRecall"] || [name hasPrefix:@"__QQGProReceiveRecall"]) return YES;
    if ([name rangeOfString:@"Recall" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Revoke" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static BOOL qqesignRecallHookExists(Class cls, SEL sel) {
    for (NSUInteger i = 0; i < gQQESignRecallHookCount; i++) {
        if (gQQESignRecallHooks[i].cls == cls && gQQESignRecallHooks[i].sel == sel) {
            return YES;
        }
    }
    return NO;
}

static void qqesignAddRecallHookRecord(Class cls, SEL sel, IMP orig) {
    if (!cls || !sel || !orig) return;
    if (qqesignRecallHookExists(cls, sel)) return;
    if (gQQESignRecallHookCount >= (sizeof(gQQESignRecallHooks) / sizeof(gQQESignRecallHooks[0]))) return;
    gQQESignRecallHooks[gQQESignRecallHookCount].cls = cls;
    gQQESignRecallHooks[gQQESignRecallHookCount].sel = sel;
    gQQESignRecallHooks[gQQESignRecallHookCount].orig = orig;
    gQQESignRecallHookCount++;
}

static IMP qqesignLookupRecallOriginal(id self, SEL _cmd) {
    if (!self || !_cmd) return NULL;
    for (Class cls = object_getClass(self); cls; cls = class_getSuperclass(cls)) {
        for (NSUInteger i = 0; i < gQQESignRecallHookCount; i++) {
            if (gQQESignRecallHooks[i].cls == cls && gQQESignRecallHooks[i].sel == _cmd) {
                return gQQESignRecallHooks[i].orig;
            }
        }
    }
    return NULL;
}

static Method qqesignFindOwnInstanceMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = methods[i];
            break;
        }
    }
    if (methods) free(methods);
    return found;
}

static BOOL qqesignSwizzleRecallMethodOnClass(Class cls,
                                              const char *selName,
                                              const char *typeEncoding,
                                              IMP newImp,
                                              const char *tag) {
    if (!cls || !selName || !newImp) return NO;

    SEL sel = sel_registerName(selName);
    Method method = qqesignFindOwnInstanceMethod(cls, sel);
    if (!method) return NO;
    if (qqesignRecallHookExists(cls, sel)) return NO;

    if (typeEncoding) {
        const char *actualType = method_getTypeEncoding(method);
        if (!actualType || strcmp(actualType, typeEncoding) != 0) return NO;
    }

    IMP orig = method_getImplementation(method);
    if (!orig || orig == newImp) return NO;

    qqesignAddRecallHookRecord(cls, sel, orig);
    method_setImplementation(method, newImp);

    NSLog(@"[QQESign] 安装防撤回 Hook: %s -[%s %s]",
          (tag ? tag : "anti-recall"),
          class_getName(cls),
          selName);
    return YES;
}

static BOOL qqesignRecallNetEngineBlocker(id self,
                                          SEL _cmd,
                                          const void *data,
                                          int bufferLen,
                                          int subcmd,
                                          void *model) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回解析: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return NO;
    }
    QQEOrigBoolRecallNetParse orig = (QQEOrigBoolRecallNetParse)qqesignLookupRecallOriginal(self, _cmd);
    return orig ? orig(self, _cmd, data, bufferLen, subcmd, model) : NO;
}

static id qqesignRecallModuleFullBlocker(id self,
                                         SEL _cmd,
                                         const void *data,
                                         int bufferLen,
                                         int subcmd,
                                         unsigned long long uin,
                                         BOOL *tracelessFlag) {
    if (pref_antiRevoke && tracelessFlag) *tracelessFlag = NO;
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截侧路撤回入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return nil;
    }
    QQEOrigIdRecallModuleFull orig = (QQEOrigIdRecallModuleFull)qqesignLookupRecallOriginal(self, _cmd);
    return orig ? orig(self, _cmd, data, bufferLen, subcmd, uin, tracelessFlag) : nil;
}

static id qqesignRecallConvertBlocker(id self,
                                      SEL _cmd,
                                      const void *recallItem,
                                      void *recallModel,
                                      int msgType,
                                      unsigned long long bindUin) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回转换: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return nil;
    }
    QQEOrigIdRecallConvert orig = (QQEOrigIdRecallConvert)qqesignLookupRecallOriginal(self, _cmd);
    return orig ? orig(self, _cmd, recallItem, recallModel, msgType, bindUin) : nil;
}

static void qqesignRecallBridgeBlocker(id self, SEL _cmd, id recallPair) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回落库: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidOneObj orig = (QQEOrigVoidOneObj)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, recallPair);
}

static void qqesignRecallOneObjectBlocker(id self, SEL _cmd, id arg1) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidOneObj orig = (QQEOrigVoidOneObj)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, arg1);
}

static void qqesignRecallThreeObjectBlocker(id self, SEL _cmd, id arg1, id arg2, id arg3) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回拉取链路: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidThreeObj orig = (QQEOrigVoidThreeObj)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, arg1, arg2, arg3);
}

static void qqesignRecallZeroArgBlocker(id self, SEL _cmd) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回零参入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidZeroArg orig = (QQEOrigVoidZeroArg)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd);
}

static BOOL qqesignRecallBoolZeroArgBlocker(id self, SEL _cmd) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 清空撤回标记: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return NO;
    }
    QQEOrigBoolZeroArg orig = (QQEOrigBoolZeroArg)qqesignLookupRecallOriginal(self, _cmd);
    return orig ? orig(self, _cmd) : NO;
}

static BOOL qqesignRecallBoolOneObjectBlocker(id self, SEL _cmd, id arg1) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回布尔入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return NO;
    }
    QQEOrigBoolOneObj orig = (QQEOrigBoolOneObj)qqesignLookupRecallOriginal(self, _cmd);
    return orig ? orig(self, _cmd, arg1) : NO;
}

static void qqesignRecallBoolSetterBlocker(id self, SEL _cmd, BOOL flag) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 阻止写入撤回标记: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidOneBool orig = (QQEOrigVoidOneBool)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, flag);
}

static void qqesignRecallOneObjectBoolBlocker(id self, SEL _cmd, id arg1, BOOL arg2) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidOneObjBool orig = (QQEOrigVoidOneObjBool)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, arg1, arg2);
}

static id qqesignRecallDecouplingPushBlocker(id self, SEL _cmd, int pushType, BOOL isRecallPush) {
    if (pref_antiRevoke && isRecallPush) {
        NSLog(@"[QQESign] 拦截撤回 push 标识生成: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return nil;
    }
    QQEOrigIdIntBool orig = (QQEOrigIdIntBool)qqesignLookupRecallOriginal(self, _cmd);
    return orig ? orig(self, _cmd, pushType, isRecallPush) : nil;
}

static void qqesignRecallGrayTipBlocker(id self,
                                        SEL _cmd,
                                        id model,
                                        id vc,
                                        id contact,
                                        unsigned int busiId) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回灰条: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidGrayTip orig = (QQEOrigVoidGrayTip)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, model, vc, contact, busiId);
}

static void qqesignRecallMsgRecall3Blocker(id self, SEL _cmd, int arg1, id arg2, unsigned long long arg3) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidMsgRecall3 orig = (QQEOrigVoidMsgRecall3)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, arg1, arg2, arg3);
}

static void qqesignRecallGuildPushBlocker(id self,
                                          SEL _cmd,
                                          long long arg1,
                                          long long arg2,
                                          long long arg3,
                                          int arg4,
                                          id arg5,
                                          id arg6,
                                          id arg7,
                                          id arg8,
                                          int arg9) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }
    QQEOrigVoidGuildPush orig = (QQEOrigVoidGuildPush)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9);
}

static void qqesignRecallNotifPostOneBlocker(id self, SEL _cmd, id notification) {
    NSString *name = nil;
    if ([notification respondsToSelector:@selector(name)]) {
        name = ((NSNotification *)notification).name;
    }
    if (pref_antiRevoke && qqesignIsRecallNotificationName(name)) {
        NSLog(@"[QQESign] 拦截撤回通知派发: -[%@ %@] %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), name);
        return;
    }
    QQEOrigVoidOneObj orig = (QQEOrigVoidOneObj)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, notification);
}

static void qqesignRecallNotifPostTwoBlocker(id self, SEL _cmd, id name, id object) {
    NSString *notifName = [name isKindOfClass:[NSString class]] ? (NSString *)name : nil;
    if (pref_antiRevoke && qqesignIsRecallNotificationName(notifName)) {
        NSLog(@"[QQESign] 拦截撤回通知派发: -[%@ %@] %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), notifName);
        return;
    }
    QQEOrigVoidTwoObj orig = (QQEOrigVoidTwoObj)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, name, object);
}

static void qqesignRecallNotifPostThreeBlocker(id self, SEL _cmd, id name, id object, id userInfo) {
    NSString *notifName = [name isKindOfClass:[NSString class]] ? (NSString *)name : nil;
    if (pref_antiRevoke && qqesignIsRecallNotificationName(notifName)) {
        NSLog(@"[QQESign] 拦截撤回通知派发: -[%@ %@] %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), notifName);
        return;
    }
    QQEOrigVoidThreeObj orig = (QQEOrigVoidThreeObj)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, name, object, userInfo);
}

static NSUInteger qqesignInstallRecallHooksPass(const char *reason) {
    NSUInteger installed = 0;

    @try {
        static const QQESignRecallMethodSpec specs[] = {
            // 普通消息主链
            { "QQMessageRecallNetEngine", "parseC2CRecallNotify:bufferLen:subcmd:model:",
              "B40@0:8r^v16i24i28^{RecallModel=}32", (IMP)qqesignRecallNetEngineBlocker, "c2c-net" },
            { "QQMessageRecallModule", "convertRecallItemToMsg:recallModel:msgType:bindUin:",
              "@44@0:8^v16^v24i32Q36", (IMP)qqesignRecallConvertBlocker, "module-convert" },
            { "QQMessageDecouplingBridge", "recallMessagePair:",
              "v24@0:8@16", (IMP)qqesignRecallBridgeBlocker, "bridge-apply" },

            // 特殊分支保留
            { "QQMessageRecallModule", "handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:",
              "@48@0:8r^v16i24i28Q32^B40", (IMP)qqesignRecallModuleFullBlocker, "side-account" },
            { "QQMessageDecouplingBridge", "generatePushUniqueIdentifier:isRecallPush:",
              "@24@0:8i16B20", (IMP)qqesignRecallDecouplingPushBlocker, "bridge-push-id" },
            { "OCIKernelMsgService", "getRecallMsgsByMsgId:msgIds:cb:",
              "v40@0:8@16@24@32", (IMP)qqesignRecallThreeObjectBlocker, "kernel-get-recall" },
            { "_TtC15NTKernelAdapter14MessageService", "getRecallMsgsWithPeer:msgIds:cb:",
              "v40@0:8@16@24@?32", (IMP)qqesignRecallThreeObjectBlocker, "swift-kernel-get-recall" },
            { "OCMsgRecallInfo", "isRecallNotify",
              "B16@0:8", (IMP)qqesignRecallBoolZeroArgBlocker, "msg-recall-flag" },
            { "OCMsgRecallInfo", "isTracelessRecall",
              "B16@0:8", (IMP)qqesignRecallBoolZeroArgBlocker, "msg-traceless-flag" },
            { "OCMsgRecallInfo", "setIsRecallNotify:",
              "v20@0:8B16", (IMP)qqesignRecallBoolSetterBlocker, "msg-recall-set" },
            { "OCMsgRecallInfo", "setIsTracelessRecall:",
              "v20@0:8B16", (IMP)qqesignRecallBoolSetterBlocker, "msg-traceless-set" },

            // 你现有代码里值得保留的显式补点
            { "GroupEmotionManager", "recallMessagePair:",
              "v24@0:8@16", (IMP)qqesignRecallBridgeBlocker, "group-emotion" },
            { "QQAIOCell", "updateCellViewRecall",
              "v16@0:8", (IMP)qqesignRecallZeroArgBlocker, "aio-cell-recall" },
            { "NudgeActionManager", "insertRecallGrayTips2AioIfneed:isGroup:",
              "v28@0:8@16B24", (IMP)qqesignRecallOneObjectBoolBlocker, "nudge-graytip" },

            // 少量明确可见的表现层补漏
            { "QQGProMsgPushManager", "msgRecallMsgNotication:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "gpro-push" },
            { "QQChatFilesRichMediaHandler", "findRecallModelAndRemove:",
              "B24@0:8@16", (IMP)qqesignRecallBoolOneObjectBlocker, "chat-files-richmedia" },
            { "QQChatFilesViewController", "msgRecallMsgNoti:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "chat-files" },
            { "QQChatFilesViewController", "showRecallAlert",
              "v16@0:8", (IMP)qqesignRecallZeroArgBlocker, "chat-files-alert" },
            { "QQRichMediaChatImagePhotoBrowserViewController", "msgRecallMsgNoti:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "richmedia-browser" },
            { "QQRichMediaChatImagePhotoBrowserViewController", "msgRecallMsgNotiForGProMsg:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "richmedia-gpro" },
            { "QQRichMediaChatImagePhotoBrowserViewController", "onFileRecallNofi:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "richmedia-file-recall" },
            { "QQRichMediaChatImagePhotoBrowserViewController", "showRecallAlert",
              "v16@0:8", (IMP)qqesignRecallZeroArgBlocker, "richmedia-alert" },

            // 浮层 / guild / UI 兜底
            { "_TtC15AIOPhotoBrowser31NTAIOPhotoBrowserViewController", "receiveRecallNotification:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "photo-browser-receive" },
            { "_TtC9NTAIOChat21NTStreamMsgAIOHandler", "receiveRecallNotification:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "stream-receive" },
            { "_TtC9NTAIOChat20NTAIOFloatEarManager", "onRecvRecallMsg:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "float-ear" },
            { "_TtC9NTAIOChat17NTAIOFloatEarPart", "recallMessageWithNotification:",
              "v24@0:8@16", (IMP)qqesignRecallOneObjectBlocker, "float-ear-part" },
            { "NTGuildMsgListener", "onMsgRecall:peerUid:seq:",
              "v36@0:8i16@20Q28", (IMP)qqesignRecallMsgRecall3Blocker, "guild-listener" },
            { "_TtC13GuildNTKernel20SWIKernelMsgListener", "onMsgRecall:peerUid:seq:",
              "v36@0:8i16@20Q28", (IMP)qqesignRecallMsgRecall3Blocker, "guild-swift-listener" },
            { "KTIKernelMsgListener", "onMsgRecall:peerUid:seq:",
              "v36@0:8i16@20Q28", (IMP)qqesignRecallMsgRecall3Blocker, "kti-listener" },
            { "GProSDKListener", "onPushRevokeGuild:operatorTinyId:memberTinyId:memberType:guildInfo:channelMap:uncategorizedChannels:categoryList:sourceType:",
              "v80@0:8q16q24q32i40@44@52@60@68i76", (IMP)qqesignRecallGuildPushBlocker, "guild-push" },

            // UI 灰条兜底
            { "NTAIOGrayTipsOtherLinkRecallHandle", "grayTipsEventWithModel:curVC:contact:busiId:",
              "v44@0:8@16@24@32I40", (IMP)qqesignRecallGrayTipBlocker, "gray-tip" },
            { "NSNotificationCenter", "postNotification:",
              "v24@0:8@16", (IMP)qqesignRecallNotifPostOneBlocker, "notif-post-1" },
            { "NSNotificationCenter", "postNotificationName:object:",
              "v32@0:8@16@24", (IMP)qqesignRecallNotifPostTwoBlocker, "notif-post-2" },
            { "NSNotificationCenter", "postNotificationName:object:userInfo:",
              "v40@0:8@16@24@32", (IMP)qqesignRecallNotifPostThreeBlocker, "notif-post-3" },
        };

        for (NSUInteger i = 0; i < sizeof(specs) / sizeof(specs[0]); i++) {
            Class cls = objc_getClass(specs[i].className);
            if (!cls) continue;
            installed += qqesignSwizzleRecallMethodOnClass(cls,
                                                           specs[i].selName,
                                                           specs[i].typeEncoding,
                                                           specs[i].newImp,
                                                           specs[i].tag);
        }
    } @catch (NSException *e) {
        NSLog(@"[QQESign] 防撤回安装异常: %@ %@", e.name, e.reason);
    }

    if (installed > 0) {
        NSLog(@"[QQESign] %s 本轮新增防撤回 Hook: %lu",
              (reason ? reason : "anti-recall"),
              (unsigned long)installed);
    } else {
        NSLog(@"[QQESign] %s 本轮未新增防撤回 Hook",
              (reason ? reason : "anti-recall"));
    }
    return installed;
}

static void qqesignRecallImageAdded(const struct mach_header *mh, intptr_t vmaddr_slide) {
    (void)mh;
    (void)vmaddr_slide;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        qqesignInstallRecallHooksPass("dyld-add-image");
    });
}

static void qqesignInstallRecallHooksWithRetry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            qqesignInstallRecallHooksPass("delayed-ctor");
        });

        _dyld_register_func_for_add_image(qqesignRecallImageAdded);

        NSArray<NSNumber *> *delays = @[@3.0, @8.0, @15.0];
        for (NSNumber *delay in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                qqesignInstallRecallHooksPass("retry");
            });
        }
    });
}

#pragma mark - 2. 闪照 — ObjC层 (OCPicElement / QQBasePhoto)
// ─────────────────────────────────────────────
// 两个类均经过 ObjC classlist 解析确认，isFlashPic / setIsFlashPic: 均存在于方法表中。
// 返回 NO 后，QQ 不再对这条消息应用闪照限制（倒计时、保存限制等）。

%hook OCPicElement

- (BOOL)isFlashPic {
    return pref_flashUnlimited ? NO : %orig;
}

- (void)setIsFlashPic:(BOOL)val {
    %orig(pref_flashUnlimited ? NO : val);
}

%end

%hook QQBasePhoto

- (BOOL)isFlashPic {
    return pref_flashUnlimited ? NO : %orig;
}

- (void)setIsFlashPic:(BOOL)val {
    %orig(pref_flashUnlimited ? NO : val);
}

%end

// ─────────────────────────────────────────────
#pragma mark - 3. 闪照 — NT Swift VC 层
// ─────────────────────────────────────────────
// Swift 类通过 @objc 桥接暴露给 ObjC runtime（__DATA_CONST,__objc_classlist 确认）

// 闪照浏览器 VC：拦截"隐藏/结束预览"使图片不消失
%hook _TtC15AIOPhotoBrowser43NTAIOFlashPicturePhotoBrowserViewController

- (void)hideFlashImgPreview {
    if (pref_flashUnlimited) {
        NSLog(@"[QQESign] 阻止 hideFlashImgPreview");
        return;
    }
    %orig;
}

- (void)finishFlashImgPreview {
    if (pref_flashUnlimited) {
        NSLog(@"[QQESign] 阻止 finishFlashImgPreview");
        return;
    }
    %orig;
}

- (void)hideSecretPictureImage {
    if (pref_flashUnlimited) return;
    %orig;
}

- (void)viewDidLoad {
    %orig;
    if (pref_flashSave) {
        // 延迟后尝试从视图层级中抓取并保存图片
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *view = (UIView *)self;
            UIImage *img = findImageInView(view);
            if (img) saveImageToCameraRoll(img);
        });
    }
}

%end

// 闪照"秘密"遮罩视图：隐藏倒计时遮罩
%hook _TtC15AIOPhotoBrowser39NTAIOFlashPicturePhotoBrowserSecretView

- (void)layoutSubviews {
    %orig;
    if (pref_flashUnlimited) {
        UIView *view = (UIView *)self;
        view.hidden = YES;
        view.alpha = 0;
    }
}

// 允许正常触摸（不拦截截图等操作）
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (pref_flashUnlimited) return;
    %orig;
}

%end

// ─────────────────────────────────────────────
#pragma mark - 4. 自定义设备名 / 电量
// ─────────────────────────────────────────────

%hook UIDevice

- (NSString *)name {
    return pref_fakeDevice ? pref_deviceName : %orig;
}

- (float)batteryLevel {
    return pref_fakeBattery ? pref_batteryLevel : %orig;
}

- (UIDeviceBatteryState)batteryState {
    if (pref_fakeBattery) {
        return pref_isCharging ? UIDeviceBatteryStateCharging : UIDeviceBatteryStateUnplugged;
    }
    return %orig;
}

%end

// ─────────────────────────────────────────────
#pragma mark - 5. 设置入口
// ─────────────────────────────────────────────

// NT 版 QQ 设置页（__DATA_CONST,__objc_classlist 中存在）
%hook QQNewSettingsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    addESignButton((UIViewController *)self, @selector(qqesign_openSettings));
}

%new
- (void)qqesign_openSettings { showQQESignSettings(); }

%end

%hook QQSettingsBaseViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    addESignButton((UIViewController *)self, @selector(qqesign_openSettings));
}

%new
- (void)qqesign_openSettings { showQQESignSettings(); }

%end

// 后备：摇一摇打开设置
%hook UIWindow

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    %orig;
    if (motion == UIEventSubtypeMotionShake) showQQESignSettings();
}

%end

// ─────────────────────────────────────────────
#pragma mark - Constructor
// ─────────────────────────────────────────────

%ctor {
    @autoreleasepool {
        loadPrefs();
        qqesignInstallRecallHooksWithRetry();
        NSLog(@"[QQESign] v2.0 Loaded (NT架构) antiRevoke=%d flashUnlimited=%d flashSave=%d fakeDevice=%d fakeBatt=%d",
              pref_antiRevoke, pref_flashUnlimited, pref_flashSave,
              pref_fakeDevice, pref_fakeBattery);
    }
}
