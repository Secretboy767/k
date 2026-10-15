#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <UIKit/UIKit.h>

@protocol ClientMenuAPI <JSExport>
JSExportAs(registerAction,
- (void)registerAction:(NSString *)title callback:(JSValue *)callback
);
- (void)notify:(NSString *)message;
@end

@interface ClientMenuBridge : NSObject <ClientMenuAPI>
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *actions;
@property(nonatomic, weak) JSContext *context;
@property(nonatomic, weak) UIWindow *window;
@end

@implementation ClientMenuBridge

- (void)registerAction:(NSString *)title callback:(JSValue *)callback {
    if (title.length == 0 || !callback || !callback.isObject) {
        NSLog(@"[ClientLoader] Ignored invalid action registration");
        return;
    }
    [self.actions addObject:@{@"title": title, @"callback": callback}];
}

- (void)notify:(NSString *)message {
    if (message.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Client Loader"
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        UIViewController *presenter = self.window.rootViewController;
        while (presenter.presentedViewController) {
            presenter = presenter.presentedViewController;
        }
        if (presenter) [presenter presentViewController:alert animated:YES completion:nil];
    });
}

@end

@interface ClientLoaderTarget : NSObject
- (void)openMenu;
@end

static ClientMenuBridge *sBridge;
static JSContext *sContext;
static UIButton *sMenuButton;
static ClientLoaderTarget *sTarget;
static BOOL sScriptsLoaded;
static NSUInteger sWindowLookupAttempts;

static void ClientMenuOpen(void);

static UIWindow *ClientLoaderFindWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    for (UIWindow *window in application.windows) {
        if (window.isKeyWindow) return window;
    }
    return nil;
}

static void ClientMenuOpen(void) {
    if (!sBridge) return;
    UIAlertController *menu = [UIAlertController
        alertControllerWithTitle:@"Client Menu"
                         message:@"Actions registered by local JavaScript files"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *action in sBridge.actions) {
        NSString *title = action[@"title"];
        JSValue *callback = action[@"callback"];
        [menu addAction:[UIAlertAction actionWithTitle:title
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *item) {
            if (callback && !callback.isUndefined) [callback callWithArguments:@[]];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Close"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    UIPopoverPresentationController *popover = menu.popoverPresentationController;
    if (popover) {
        popover.sourceView = sMenuButton;
        popover.sourceRect = sMenuButton.bounds;
    }
    UIViewController *presenter = sBridge.window.rootViewController;
    while (presenter.presentedViewController) {
        presenter = presenter.presentedViewController;
    }
    if (presenter) [presenter presentViewController:menu animated:YES completion:nil];
}

static void ClientLoaderInstallButton(UIWindow *window) {
    if (sMenuButton && sMenuButton.superview == window) return;
    [sMenuButton removeFromSuperview];
    CGFloat side = 54.0;
    sMenuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    sMenuButton.frame = CGRectMake(CGRectGetWidth(window.bounds) - side - 16.0,
                                   CGRectGetHeight(window.bounds) * 0.70,
                                   side,
                                   side);
    sMenuButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                   UIViewAutoresizingFlexibleTopMargin;
    sMenuButton.backgroundColor = [UIColor colorWithRed:0.12 green:0.45 blue:0.85 alpha:0.94];
    sMenuButton.layer.cornerRadius = side / 2.0;
    sMenuButton.layer.borderWidth = 1.0;
    sMenuButton.layer.borderColor = UIColor.whiteColor.CGColor;
    [sMenuButton setTitle:@"C" forState:UIControlStateNormal];
    [sMenuButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    sMenuButton.titleLabel.font = [UIFont boldSystemFontOfSize:22.0];
    sMenuButton.accessibilityLabel = @"Open Client Menu";
    if (!sTarget) sTarget = [ClientLoaderTarget new];
    [sMenuButton addTarget:sTarget
                    action:@selector(openMenu)
          forControlEvents:UIControlEventTouchUpInside];
    [window addSubview:sMenuButton];
    sBridge.window = window;
}

@implementation ClientLoaderTarget
- (void)openMenu {
    ClientMenuOpen();
}
@end

static void ClientLoaderLoadScripts(void) {
    if (sScriptsLoaded) return;

    NSURL *documents = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory
               inDomains:NSUserDomainMask] firstObject];
    NSURL *scriptDirectory = [[documents URLByAppendingPathComponent:@"ClientLoader" isDirectory:YES]
        URLByAppendingPathComponent:@"scripts" isDirectory:YES];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:scriptDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError]) {
        NSLog(@"[ClientLoader] Could not create script directory: %@", directoryError);
        return;
    }
    sScriptsLoaded = YES;

    sBridge = [ClientMenuBridge new];
    sBridge.actions = [NSMutableArray array];
    sContext = [JSContext new];
    sBridge.context = sContext;
    sContext[@"ClientMenu"] = sBridge;
    sContext.exceptionHandler = ^(JSContext *context, JSValue *exception) {
        NSLog(@"[ClientLoader] JavaScript exception: %@", exception);
    };

    NSError *listingError = nil;
    NSArray<NSURL *> *items = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:scriptDirectory
       includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                          options:NSDirectoryEnumerationSkipsHiddenFiles
                            error:&listingError];
    if (!items) {
        NSLog(@"[ClientLoader] Could not list scripts: %@", listingError);
        return;
    }

    NSArray<NSURL *> *scripts = [[items filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSURL *url, __unused NSDictionary *bindings) {
            NSNumber *isRegularFile = nil;
            [url getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:nil];
            return isRegularFile.boolValue && [url.pathExtension.lowercaseString isEqualToString:@"js"];
        }]] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
        }];

    for (NSURL *scriptURL in scripts) {
        NSError *readError = nil;
        NSString *source = [NSString stringWithContentsOfURL:scriptURL
                                                   encoding:NSUTF8StringEncoding
                                                      error:&readError];
        if (!source) {
            NSLog(@"[ClientLoader] Could not read %@: %@", scriptURL.lastPathComponent, readError);
            continue;
        }
        [sContext evaluateScript:source withSourceURL:scriptURL];
    }
    NSLog(@"[ClientLoader] Loaded %lu JavaScript file(s) from %@",
          (unsigned long)scripts.count,
          scriptDirectory.path);
}

static void ClientLoaderStart(void) {
    ClientLoaderLoadScripts();
    UIWindow *window = ClientLoaderFindWindow();
    if (window) {
        sWindowLookupAttempts = 0;
        ClientLoaderInstallButton(window);
        return;
    }
    if (++sWindowLookupAttempts > 120) {
        NSLog(@"[ClientLoader] Gave up waiting for an active app window");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{ ClientLoaderStart(); });
}

__attribute__((constructor))
static void ClientLoaderInitialize(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *notification) {
                sWindowLookupAttempts = 0;
                ClientLoaderStart();
            }];
            ClientLoaderStart();
        });
    }
}
