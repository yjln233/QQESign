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
//   NT 撤回流：网络解析(QQMessageRecallNetEngine) → 模块处理(QQMessageRecallModule)
//   → UI灰条(NTAIOGrayTipsOtherLinkRecallHandle)。三层全部拦截。
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

typedef struct {
    Class cls;
    SEL sel;
    IMP orig;
} QQESignRecallHookRecord;

static QQESignRecallHookRecord gQQESignRecallHooks[64];
static NSUInteger gQQESignRecallHookCount = 0;

typedef void (*QQEOrigVoidNoArg)(id, SEL);
typedef void (*QQEOrigVoidOneObj)(id, SEL, id);
typedef void (*QQEOrigVoidThreeArgs)(id, SEL, id, unsigned long long, int);
typedef void (*QQEOrigVoidFourArgs)(id, SEL, id, NSUInteger, int, id);
typedef void (*QQEOrigVoidFiveArgs)(id, SEL, id, NSUInteger, int, unsigned long long, int);
typedef void (*QQEOrigVoidGrayTip)(id, SEL, id, id, id, id);

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
    Class cls = object_getClass(self);
    while (cls) {
        for (NSUInteger i = 0; i < gQQESignRecallHookCount; i++) {
            if (gQQESignRecallHooks[i].cls == cls && gQQESignRecallHooks[i].sel == _cmd) {
                return gQQESignRecallHooks[i].orig;
            }
        }
        cls = class_getSuperclass(cls);
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

static BOOL qqesignSwizzleRecallMethodOnClass(Class cls, const char *selName, IMP newImp, const char *tag) {
    if (!cls || !selName || !newImp) return NO;

    SEL sel = sel_registerName(selName);
    Method method = qqesignFindOwnInstanceMethod(cls, sel);
    if (!method) return NO;
    if (qqesignRecallHookExists(cls, sel)) return NO;

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

static void qqesignRecallNoArgBlocker(id self, SEL _cmd) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }

    QQEOrigVoidNoArg orig = (QQEOrigVoidNoArg)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd);
}

static void qqesignRecallOneObjectBlocker(id self, SEL _cmd, id arg1) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回入口: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }

    QQEOrigVoidOneObj orig = (QQEOrigVoidOneObj)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, arg1);
}

static void qqesignRecallModuleShortBlocker(id self, SEL _cmd, id data, unsigned long long uin, int flag) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截 QQMessageRecallModule short recall");
        return;
    }

    QQEOrigVoidThreeArgs orig = (QQEOrigVoidThreeArgs)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, data, uin, flag);
}

static void qqesignRecallNetEngineBlocker(id self, SEL _cmd, id data, NSUInteger len, int subcmd, id model) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截 QQMessageRecallNetEngine parseC2CRecallNotify");
        return;
    }

    QQEOrigVoidFourArgs orig = (QQEOrigVoidFourArgs)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, data, len, subcmd, model);
}

static void qqesignRecallModuleFullBlocker(id self, SEL _cmd, id data, NSUInteger len, int subcmd, unsigned long long uin, int flag) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截 QQMessageRecallModule full recall");
        return;
    }

    QQEOrigVoidFiveArgs orig = (QQEOrigVoidFiveArgs)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, data, len, subcmd, uin, flag);
}

static void qqesignRecallGrayTipBlocker(id self, SEL _cmd, id model, id vc, id contact, id busiId) {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回灰条: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
        return;
    }

    QQEOrigVoidGrayTip orig = (QQEOrigVoidGrayTip)qqesignLookupRecallOriginal(self, _cmd);
    if (orig) orig(self, _cmd, model, vc, contact, busiId);
}

static NSUInteger qqesignInstallRecallHooksPass(void) {
    NSUInteger installed = 0;

    const char *targetClasses[] = {
        "QQMessageRecallNetEngine",
        "QQMessageRecallModule",
        "QQMessageRecallPackageHandler",
        "NTAIOChatRecallService",
        "NTAIOMenuRecallService",
        "CanRecallHandler",
        "NTAIOGrayTipsOtherLinkRecallHandle",
    };

    const NSUInteger targetClassCount = sizeof(targetClasses) / sizeof(targetClasses[0]);
    for (NSUInteger i = 0; i < targetClassCount; i++) {
        Class cls = objc_getClass(targetClasses[i]);
        if (!cls) continue;

        installed += qqesignSwizzleRecallMethodOnClass(cls, "parseC2CRecallNotify:bufferLen:subcmd:model:", (IMP)qqesignRecallNetEngineBlocker, "net");
        installed += qqesignSwizzleRecallMethodOnClass(cls, "handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:", (IMP)qqesignRecallModuleFullBlocker, "module-full");
        installed += qqesignSwizzleRecallMethodOnClass(cls, "handleSideAccountRecallNotify:bindUin:tracelessFlag:", (IMP)qqesignRecallModuleShortBlocker, "module-short");
        installed += qqesignSwizzleRecallMethodOnClass(cls, "receiveRecallNotification:", (IMP)qqesignRecallOneObjectBlocker, "receive");
        installed += qqesignSwizzleRecallMethodOnClass(cls, "receiveRecallNotificationAt:", (IMP)qqesignRecallOneObjectBlocker, "receive-at");
        installed += qqesignSwizzleRecallMethodOnClass(cls, "handleRecallMsg:", (IMP)qqesignRecallOneObjectBlocker, "handle-msg");
        installed += qqesignSwizzleRecallMethodOnClass(cls, "TryHandleAllQQRecallNotify", (IMP)qqesignRecallNoArgBlocker, "try-all");
    }

    Class grayTipCls = objc_getClass("NTAIOGrayTipsOtherLinkRecallHandle");
    if (grayTipCls) {
        installed += qqesignSwizzleRecallMethodOnClass(grayTipCls,
                                                       "grayTipsEventWithModel:curVC:contact:busiId:",
                                                       (IMP)qqesignRecallGrayTipBlocker,
                                                       "gray-tip");
    }

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return installed;

    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        if (!name) continue;
        if (!strstr(name, "Recall") && !strstr(name, "Revoke")) continue;

        installed += qqesignSwizzleRecallMethodOnClass(cls, "receiveRecallNotification:", (IMP)qqesignRecallOneObjectBlocker, "scan-receive");
        installed += qqesignSwizzleRecallMethodOnClass(cls, "receiveRecallNotificationAt:", (IMP)qqesignRecallOneObjectBlocker, "scan-receive-at");
        installed += qqesignSwizzleRecallMethodOnClass(cls, "handleRecallMsg:", (IMP)qqesignRecallOneObjectBlocker, "scan-handle-msg");
        installed += qqesignSwizzleRecallMethodOnClass(cls, "TryHandleAllQQRecallNotify", (IMP)qqesignRecallNoArgBlocker, "scan-try-all");
    }

    free(classes);
    return installed;
}

static void qqesignInstallRecallHooksWithRetry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSNumber *> *delays = @[@0.0, @0.8, @2.0, @5.0, @10.0];
        for (NSNumber *delay in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NSUInteger installed = qqesignInstallRecallHooksPass();
                if (installed > 0) {
                    NSLog(@"[QQESign] 本轮新增防撤回 Hook: %lu", (unsigned long)installed);
                }
            });
        }
    });
}

// ─────────────────────────────────────────────
#pragma mark - 1. 防撤回 — 模块层拦截 (NT架构)
// ─────────────────────────────────────────────
// NT QQ 撤回真实链路（ObjC classlist 验证）：
//   网络层解析 → QQMessageRecallNetEngine     (parseC2CRecallNotify:...)
//   模块处理层 → QQMessageRecallModule        (handleSideAccountRecallNotify:...)
//   灰条展示层 → NTAIOGrayTipsOtherLinkRecallHandle (grayTipsEventWithModel:...)
//
// NSNotification 方案已验证无效（NT 架构 UI 通过 KVO/数据绑定更新）。
// 改为在 ObjC 模块层直接拦截，多层叠加保证覆盖各种聊天场景。

// 层1: 网络解析层 — C2C 撤回协议包解析入口（最早截断点）
%hook QQMessageRecallNetEngine

- (void)parseC2CRecallNotify:(id)data bufferLen:(NSUInteger)len subcmd:(int)subcmd model:(id)model {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截 C2C 撤回解析");
        return;
    }
    %orig;
}

%end

// 层2: 模块处理层 — 账号撤回通知处理（C2C + 群均经过此处）
%hook QQMessageRecallModule

- (void)handleSideAccountRecallNotify:(id)data bufferLen:(NSUInteger)len subcmd:(int)subcmd bindUin:(unsigned long long)uin tracelessFlag:(int)flag {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截 QQMessageRecallModule handleSideAccountRecallNotify");
        return;
    }
    %orig;
}

%end

// 层3: UI 灰条层 — 拦截"xxx 撤回了一条消息"灰色提示渲染
%hook NTAIOGrayTipsOtherLinkRecallHandle

- (void)grayTipsEventWithModel:(id)model curVC:(id)vc contact:(id)contact busiId:(id)busiId {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截撤回灰条渲染");
        return;
    }
    %orig;
}

%end

// ─────────────────────────────────────────────
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
