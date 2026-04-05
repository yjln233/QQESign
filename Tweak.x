// QQESign — 免越狱轻松签版
// 防撤回 / 闪照保存+无限查看 / 自定义设备名+电量
// Target: com.tencent.mqq (arm64) — sideload injection

%config(generator=internal)
//
// 与越狱版区别：
//   1. 使用 Logos internal generator (ObjC runtime)，无需 CydiaSubstrate
//   2. 偏好存储使用 NSUserDefaults（沙盒内），无需 PreferenceLoader
//   3. 内建应用内设置界面，长按 QQ 设置页标题触发
//
// Swift class mangled names (NTAIOChat module):
//   NTAIORevokeGrayTipsModel        → _TtC9NTAIOChat24NTAIORevokeGrayTipsModel
//   NTAIOChatRevokeGrayTipsModel    → _TtC9NTAIOChat28NTAIOChatRevokeGrayTipsModel
//   NTAIORichRevokeTipsElement      → _TtC9NTAIOChat26NTAIORichRevokeTipsElement

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

// ─────────────────────────────────────────────
#pragma mark - Preferences (sandbox-safe)
// ─────────────────────────────────────────────

static NSString *const kPrefSuite = @"com.qqesign.prefs";
static BOOL   pref_antiRevoke     = YES;
static BOOL   pref_flashSave      = YES;
static BOOL   pref_flashUnlimited = YES;
static BOOL   pref_fakeDevice     = NO;
static NSString *pref_deviceName  = @"iPhone 16 Pro";
static BOOL   pref_fakeBattery    = NO;
static float  pref_batteryLevel   = 0.80f;
static BOOL   pref_isCharging     = NO;

static NSUserDefaults *tweakDefaults(void) {
    static NSUserDefaults *ud = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ud = [[NSUserDefaults alloc] initWithSuiteName:kPrefSuite];
        // 注册默认值
        [ud registerDefaults:@{
            @"antiRevoke":     @YES,
            @"flashSave":      @YES,
            @"flashUnlimited": @YES,
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
    pref_flashSave      = [ud boolForKey:@"flashSave"];
    pref_flashUnlimited = [ud boolForKey:@"flashUnlimited"];
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
    BOOL authorized = (s == PHAuthorizationStatusAuthorized);
    if (@available(iOS 14.0, *)) {
        authorized = authorized || (s == PHAuthorizationStatusLimited);
    }
    if (authorized) {
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromImage:image];
        } completionHandler:^(BOOL ok, NSError *err) {
            NSLog(@"[QQESign] 闪照保存%@", ok ? @"成功" : ([NSString stringWithFormat:@"失败: %@", err]));
        }];
    }
}

static void saveFilePathToCameraRoll(NSString *path) {
    if (!path) return;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (img) saveImageToCameraRoll(img);
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
    UIApplication *app = [UIApplication sharedApplication];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) return window;
            }
            for (UIWindow *window in windowScene.windows) {
                if (!window.hidden) return window;
            }
        }
    }
    if (app.keyWindow) return app.keyWindow;
    for (UIWindow *window in app.windows) {
        if (window.isKeyWindow) return window;
    }
    for (UIWindow *window in app.windows) {
        if (!window.hidden) return window;
    }
    return nil;
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissSelf)];
    [self rebuildSections];
}

- (void)rebuildSections {
    _sectionTitles = @[@"消息防撤回", @"闪照设置", @"自定义设备名", @"自定义电量", @"关于"];
    _sections = @[
        // 消息防撤回
        @[@{@"title": @"开启防撤回", @"key": @"antiRevoke", @"type": @"switch"}],
        // 闪照设置
        @[
            @{@"title": @"自动保存闪照到相册", @"key": @"flashSave", @"type": @"switch"},
            @{@"title": @"无限次查看闪照", @"key": @"flashUnlimited", @"type": @"switch"},
        ],
        // 自定义设备名
        @[
            @{@"title": @"启用自定义设备名", @"key": @"fakeDevice", @"type": @"switch"},
            @{@"title": @"设备名称", @"key": @"deviceName", @"type": @"text"},
        ],
        // 自定义电量
        @[
            @{@"title": @"启用自定义电量", @"key": @"fakeBattery", @"type": @"switch"},
            @{@"title": @"电量 (0~100)", @"key": @"batteryLevel", @"type": @"number"},
            @{@"title": @"模拟充电中", @"key": @"isCharging", @"type": @"switch"},
        ],
        // 关于
        @[@{@"title": @"QQESign v1.0.0\n防撤回 · 闪照保存 · 无限查看闪照\n自定义设备名与电量", @"type": @"info"}],
    ];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark UITableView DataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return _sectionTitles[section];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _sections[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = _sections[indexPath.section][indexPath.row];
    NSString *type = item[@"type"];
    NSString *key  = item[@"key"];

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = item[@"title"];
    cell.textLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if ([type isEqualToString:@"switch"]) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [tweakDefaults() boolForKey:key];
        sw.tag = indexPath.section * 100 + indexPath.row;
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if ([type isEqualToString:@"text"]) {
        cell.detailTextLabel.text = [tweakDefaults() stringForKey:key] ?: @"";
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if ([type isEqualToString:@"number"]) {
        float val = [tweakDefaults() floatForKey:key];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", val * 100];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    // "info" type: just label, no accessory

    return cell;
}

#pragma mark UITableView Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *item = _sections[indexPath.section][indexPath.row];
    NSString *type = item[@"type"];
    NSString *key  = item[@"key"];

    if ([type isEqualToString:@"text"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:item[@"title"]
                                                                      message:nil
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = [tweakDefaults() stringForKey:key];
            tf.placeholder = @"iPhone 16 Pro";
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *val = alert.textFields.firstObject.text;
            if (val.length > 0) {
                [tweakDefaults() setObject:val forKey:key];
                [tweakDefaults() synchronize];
                loadPrefs();
                [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
            }
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if ([type isEqualToString:@"number"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:item[@"title"]
                                                                      message:@"输入 0~100 之间的整数"
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = [NSString stringWithFormat:@"%.0f", [tweakDefaults() floatForKey:key] * 100];
            tf.keyboardType = UIKeyboardTypeNumberPad;
            tf.placeholder = @"80";
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *val = alert.textFields.firstObject.text;
            float f = [val floatValue] / 100.0f;
            if (f < 0) f = 0;
            if (f > 1) f = 1;
            [tweakDefaults() setFloat:f forKey:key];
            [tweakDefaults() synchronize];
            loadPrefs();
            [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark Switch handler

- (void)switchChanged:(UISwitch *)sw {
    NSInteger section = sw.tag / 100;
    NSInteger row = sw.tag % 100;
    NSDictionary *item = _sections[section][row];
    NSString *key = item[@"key"];
    [tweakDefaults() setBool:sw.on forKey:key];
    [tweakDefaults() synchronize];
    loadPrefs();
}

@end

// 弹出设置界面的全局方法
static void showQQESignSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = activeForegroundWindow();
        if (!win) return;
        UIViewController *root = win.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;

        UITableViewStyle style = UITableViewStyleGrouped;
        if (@available(iOS 13.0, *)) {
            style = UITableViewStyleInsetGrouped;
        }
        QQESignSettingsController *vc = [[QQESignSettingsController alloc] initWithStyle:style];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [root presentViewController:nav animated:YES completion:nil];
    });
}

static void installSettingsEntryButton(UIViewController *vc, id target, SEL action) {
    if (!vc) return;
    for (UIBarButtonItem *item in vc.navigationItem.rightBarButtonItems) {
        if ([item.title isEqualToString:@"ESign"]) return;
    }
    if ([vc.navigationItem.rightBarButtonItem.title isEqualToString:@"ESign"]) return;

    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"ESign"
                                                           style:UIBarButtonItemStylePlain
                                                          target:target
                                                          action:action];
    if (vc.navigationItem.rightBarButtonItems.count > 0) {
        NSMutableArray *items = [vc.navigationItem.rightBarButtonItems mutableCopy];
        [items addObject:btn];
        vc.navigationItem.rightBarButtonItems = items;
    } else {
        vc.navigationItem.rightBarButtonItem = btn;
    }
}

// ─────────────────────────────────────────────
#pragma mark - Dynamic revoke hooks (Swift classes)
// ─────────────────────────────────────────────
// QQ NT 的撤回灰色提示类是 Swift 类，轻松签注入时机往往早于业务模块完成类注册，需要延迟重试。

static const char *kQQESignRevokeClassNames[] = {
    "_TtC9NTAIOChat24NTAIORevokeGrayTipsModel",
    "_TtC9NTAIOChat28NTAIOChatRevokeGrayTipsModel",
    "_TtC9NTAIOChat26NTAIORichRevokeTipsElement",
};
static BOOL gQQESignRevokeClassHooked[] = { NO, NO, NO };
static BOOL gQQESignRevokeHooksReady = NO;
static BOOL gQQESignRevokeRetryScheduled = NO;
static NSUInteger gQQESignRevokeRetryCount = 0;
static const NSUInteger kQQESignRevokeMaxRetries = 8;
static id gQQESignDidFinishLaunchingObserver = nil;
static id gQQESignDidBecomeActiveObserver = nil;

static void removeRevokeHookObservers(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    if (gQQESignDidFinishLaunchingObserver) {
        [center removeObserver:gQQESignDidFinishLaunchingObserver];
        gQQESignDidFinishLaunchingObserver = nil;
    }
    if (gQQESignDidBecomeActiveObserver) {
        [center removeObserver:gQQESignDidBecomeActiveObserver];
        gQQESignDidBecomeActiveObserver = nil;
    }
}

static BOOL hookRevokeClasses(void) {
    if (gQQESignRevokeHooksReady) return YES;

    NSUInteger hookedCount = 0;
    SEL allocSel = @selector(alloc);
    for (int i = 0; i < 3; i++) {
        const char *className = kQQESignRevokeClassNames[i];
        if (gQQESignRevokeClassHooked[i]) {
            hookedCount++;
            continue;
        }

        Class cls = objc_getClass(className);
        if (!cls) {
            NSLog(@"[QQESign] Swift 撤回类尚未注册: %s", className);
            continue;
        }

        Class meta = object_getClass(cls);
        Method m = class_getClassMethod(cls, allocSel);
        if (!meta || !m) {
            NSLog(@"[QQESign] Swift 撤回类缺少 +alloc: %s", className);
            continue;
        }

        __block IMP origIMP = method_getImplementation(m);
        IMP newIMP = imp_implementationWithBlock(^id(id self_) {
            if (pref_antiRevoke) {
                NSLog(@"[QQESign] 拦截撤回类 alloc: %s", className);
                return nil;
            }
            return ((id(*)(id, SEL))origIMP)(self_, allocSel);
        });
        class_replaceMethod(meta, allocSel, newIMP, method_getTypeEncoding(m));
        gQQESignRevokeClassHooked[i] = YES;
        hookedCount++;
        NSLog(@"[QQESign] Hooked +alloc on %s", className);
    }

    gQQESignRevokeHooksReady = (hookedCount == 3);
    if (gQQESignRevokeHooksReady) {
        NSLog(@"[QQESign] Swift 撤回类 Hook 已全部安装");
        removeRevokeHookObservers();
    }

    return gQQESignRevokeHooksReady;
}

static void scheduleRevokeHookRetryAfter(NSTimeInterval delay);
static void performRevokeHookRetry(void) {
    gQQESignRevokeRetryScheduled = NO;

    if (hookRevokeClasses()) return;
    if (gQQESignRevokeRetryCount >= kQQESignRevokeMaxRetries) {
        NSLog(@"[QQESign] Swift 撤回类多次重试后仍未全部就绪，等待应用再次激活后继续尝试");
        return;
    }

    gQQESignRevokeRetryCount++;
    scheduleRevokeHookRetryAfter(1.0);
}

static void scheduleRevokeHookRetryAfter(NSTimeInterval delay) {
    if (gQQESignRevokeHooksReady || gQQESignRevokeRetryScheduled) return;
    gQQESignRevokeRetryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        performRevokeHookRetry();
    });
}

static void restartRevokeHookRetryWindow(NSTimeInterval initialDelay, NSString *reason) {
    if (gQQESignRevokeHooksReady || gQQESignRevokeRetryScheduled) return;

    gQQESignRevokeRetryCount = 0;
    NSLog(@"[QQESign] 开始延迟安装 Swift 撤回 Hook: %@", reason);
    scheduleRevokeHookRetryAfter(initialDelay);
}

static void installRevokeHookObservers(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

        gQQESignDidFinishLaunchingObserver =
            [center addObserverForName:UIApplicationDidFinishLaunchingNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
            (void)note;
            restartRevokeHookRetryWindow(1.0, @"UIApplicationDidFinishLaunchingNotification");
        }];

        gQQESignDidBecomeActiveObserver =
            [center addObserverForName:UIApplicationDidBecomeActiveNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
            (void)note;
            restartRevokeHookRetryWindow(0.5, @"UIApplicationDidBecomeActiveNotification");
        }];
    });
}

// ==========================================
// 核心分组 1: QQ 业务类（需延迟初始化）
// ==========================================
%group QQBusinessHooks

// ─────────────────────────────────────────────
#pragma mark - 1. 防撤回 — ObjC layer
// ─────────────────────────────────────────────

%hook RevokeMsgFlow

- (void)start {
    if (pref_antiRevoke) {
        NSLog(@"[QQESign] 拦截 RevokeMsgFlow start");
        return;
    }
    %orig;
}

%end

%hook RevokeMsgCellView

- (void)layoutSubviews {
    %orig;
    if (pref_antiRevoke) {
        UIView *view = (UIView *)self;
        view.hidden = YES;
        [view removeFromSuperview];
    }
}

%end

// ─────────────────────────────────────────────
#pragma mark - 2. 闪照 — 自动保存 + 无限查看
// ─────────────────────────────────────────────

%hook AIOFlashPicturePhotoBrowserViewModel

- (void)startDealWithFlashPicture {
    if (pref_flashSave) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIWindow *win = activeForegroundWindow();
            UIImage *img = findImageInView(win);
            if (img) saveImageToCameraRoll(img);
        });
    }
    if (pref_flashUnlimited) {
        NSLog(@"[QQESign] 跳过闪照倒计时");
        return;
    }
    %orig;
}

%end

%hook NTAIOChatFlashPicContentViewModel

- (NSInteger)remainCount {
    return pref_flashUnlimited ? 99 : %orig;
}

- (BOOL)isExpired {
    return pref_flashUnlimited ? NO : %orig;
}

- (BOOL)canSeeFlash {
    return pref_flashUnlimited ? YES : %orig;
}

%end

%hook AIOFlashPicturePhotoBrowserSecretView

- (void)animationForShowImage {
    if (!pref_flashUnlimited) %orig;
}

- (void)layoutSubviews {
    %orig;
    if (pref_flashUnlimited) {
        UIView *view = (UIView *)self;
        view.hidden = YES;
        view.alpha  = 0.0f;
    }
}

%end

%hook NTAIOChatFlashPicDownloader

- (void)downloadSuccess:(id)result {
    %orig;
    if (!pref_flashSave) return;
    NSString *path = nil;
    for (NSString *key in @[@"localPath", @"filePath", @"imagePath", @"cachePath", @"path"]) {
        id val = [result valueForKey:key];
        if ([val isKindOfClass:[NSString class]]) { path = val; break; }
    }
    if (path) {
        saveFilePathToCameraRoll(path);
    } else if ([result isKindOfClass:[UIImage class]]) {
        saveImageToCameraRoll((UIImage *)result);
    }
}

%end

%hook AIOFlashPictureCellView

- (void)configWithViewModel:(id)vm {
    %orig;
    if (!pref_flashSave) return;
    for (NSString *key in @[@"localPath", @"imagePath", @"filePath", @"thumbPath"]) {
        NSString *path = [vm valueForKey:key];
        if ([path isKindOfClass:[NSString class]] && path.length > 0) {
            saveFilePathToCameraRoll(path);
            break;
        }
    }
}

%end

%end // 结束 QQBusinessHooks 分组

// ==========================================
// 核心分组 2: 系统级类（可立即初始化）
// ==========================================
%group SystemHooks

// ─────────────────────────────────────────────
#pragma mark - 3+4. 自定义设备名 / 电量 / 充电状态
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
#pragma mark - 5. 设置入口 — Hook QQ 设置页
// ─────────────────────────────────────────────

%hook QQSettingsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    installSettingsEntryButton((UIViewController *)self, self, @selector(qqesign_openSettings));
}

%new
- (void)qqesign_openSettings {
    showQQESignSettings();
}

%end

%hook QQNewSettingsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    installSettingsEntryButton((UIViewController *)self, self, @selector(qqesign_openSettings));
}

%new
- (void)qqesign_openSettings {
    showQQESignSettings();
}

%end

%hook QQSettingsBaseViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    installSettingsEntryButton((UIViewController *)self, self, @selector(qqesign_openSettings));
}

%new
- (void)qqesign_openSettings {
    showQQESignSettings();
}

%end

%hook QQBaseSettingsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    installSettingsEntryButton((UIViewController *)self, self, @selector(qqesign_openSettings));
}

%new
- (void)qqesign_openSettings {
    showQQESignSettings();
}

%end

%hook UIWindow

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    %orig;
    if (motion == UIEventSubtypeMotionShake) {
        showQQESignSettings();
    }
}

%end

%end // 结束 SystemHooks 分组


// ─────────────────────────────────────────────
#pragma mark - Constructor
// ─────────────────────────────────────────────

%ctor {
    @autoreleasepool {
        loadPrefs();
        
        // 1. 立即初始化系统及设置界面的 Hook（确保电量、摇一摇、设置按钮立刻生效）
        %init(SystemHooks);
        
        // 2. 延迟 3 秒初始化 QQ 业务相关 Hook（解决闪照和 Objective-C 防撤回失效的问题）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            %init(QQBusinessHooks);
            NSLog(@"[QQESign] 业务类 Hook (防撤回/闪照) 已加载");
        });

        // 3. 启动 Swift 撤回类的重试监听机制（你新加的机制，保留不动）
        installRevokeHookObservers();
        restartRevokeHookRetryWindow(3.0, @"ctor initial delay");
        
        NSLog(@"[QQESign] Loaded — sideload/arm64 (antiRevoke=%d flashSave=%d flashUnlim=%d fakeDevice=%d fakeBatt=%d)",
              pref_antiRevoke, pref_flashSave, pref_flashUnlimited,
              pref_fakeDevice, pref_fakeBattery);
    }
}