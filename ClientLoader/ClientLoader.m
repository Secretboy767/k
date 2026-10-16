#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <unistd.h>

@class ClientMenuPanel;

@protocol ClientMenuAPI <JSExport>
JSExportAs(registerAction,
- (void)registerAction:(NSString *)title callback:(JSValue *)callback
);
JSExportAs(registerFeature,
- (void)registerFeature:(NSString *)title enabled:(BOOL)enabled callback:(JSValue *)callback
);
JSExportAs(isFeatureEnabled,
- (BOOL)isFeatureEnabled:(NSString *)title
);
- (void)notify:(NSString *)message;
@end

@interface ClientMenuBridge : NSObject <ClientMenuAPI>
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *actions;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *features;
@property(nonatomic, weak) JSContext *context;
@property(nonatomic, weak) UIWindow *window;
- (void)setFeature:(NSString *)title enabled:(BOOL)enabled;
@end

@interface ClientLoaderTarget : NSObject
- (void)runCustomAction:(UIButton *)sender;
@end

@interface ClientDraggableButton : UIButton
@property(nonatomic) CGPoint touchStart;
@property(nonatomic) CGPoint initialCenter;
@property(nonatomic) BOOL didMove;
@end

@interface ClientMenuPanel : UIView
- (instancetype)initWithWindow:(UIWindow *)window bridge:(ClientMenuBridge *)bridge;
- (void)reloadContent;
@end

static NSString *const kClientLoaderHapticsKey = @"ClientLoader.haptics";
static NSString *const kClientLoaderButtonsVisibleKey = @"ClientLoader.customButtonsVisible";
static NSString *const kClientLoaderButtonTitlesKey = @"ClientLoader.customButtonTitles";
static NSString *const kClientLoaderButtonXKey = @"ClientLoader.buttonCenterX";
static NSString *const kClientLoaderButtonYKey = @"ClientLoader.buttonCenterY";
static NSString *const kClientLoaderFeaturePrefix = @"ClientLoader.feature.";
static NSString *const kClientLoaderAccent = @"#A879FF";

static ClientMenuBridge *sBridge;
static JSContext *sContext;
static UIButton *sMenuButton;
static UIStackView *sCustomButtonStack;
static ClientLoaderTarget *sTarget;
static ClientMenuPanel *sMenuPanel;
static BOOL sScriptsLoaded;
static NSUInteger sWindowLookupAttempts;
static NSObject *sLogLock;
static NSUncaughtExceptionHandler *sPreviousUncaughtExceptionHandler;

static void ClientMenuOpen(void);
static void ClientMenuRefresh(void);
static void ClientLoaderRenderCustomButtons(void);
static void ClientLoaderSaveMenuButtonPosition(void);
static void ClientLoaderClampButton(UIButton *button, UIWindow *window);

static void ClientLoaderLog(NSString *message) {
    NSLog(@"[ClientLoader] %@", message);

    @synchronized (sLogLock) {
        NSURL *documentsURL = [[[NSFileManager defaultManager]
            URLsForDirectory:NSDocumentDirectory
                   inDomains:NSUserDomainMask] firstObject];
        if (!documentsURL) {
            NSLog(@"[ClientLoader] Could not locate Documents directory for log file");
            return;
        }

        NSURL *directoryURL = [documentsURL URLByAppendingPathComponent:@"ClientLoader"
                                                            isDirectory:YES];
        NSError *directoryError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&directoryError]) {
            NSLog(@"[ClientLoader] Could not create log directory: %@", directoryError);
            return;
        }

        NSURL *logURL = [directoryURL URLByAppendingPathComponent:@"ClientLoader.log"];
        int descriptor = open(logURL.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (descriptor < 0) {
            NSLog(@"[ClientLoader] Could not open log file: %s", strerror(errno));
            return;
        }

        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                          [formatter stringFromDate:[NSDate date]], message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        const uint8_t *bytes = data.bytes;
        size_t remaining = data.length;
        while (remaining > 0) {
            ssize_t written = write(descriptor, bytes, remaining);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                int writeError = errno;
                close(descriptor);
                NSLog(@"[ClientLoader] Could not write log file: %s", strerror(writeError));
                return;
            }
            bytes += written;
            remaining -= (size_t)written;
        }
        close(descriptor);
    }
}

static void ClientLoaderHandleUncaughtException(NSException *exception) {
    NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"];
    ClientLoaderLog([NSString stringWithFormat:
        @"FATAL: uncaught Objective-C exception %@: %@\nCall stack:\n%@",
        exception.name, exception.reason ?: @"(no reason)", stack]);
    if (sPreviousUncaughtExceptionHandler &&
        sPreviousUncaughtExceptionHandler != ClientLoaderHandleUncaughtException) {
        sPreviousUncaughtExceptionHandler(exception);
    }
}

static BOOL ClientLoaderHapticsEnabled(void) {
    id savedValue = [NSUserDefaults.standardUserDefaults objectForKey:kClientLoaderHapticsKey];
    return savedValue ? [savedValue boolValue] : YES;
}

static UIColor *ClientColor(NSString *hex, CGFloat alpha) {
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:
        [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString]];
    [scanner scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:alpha];
}

@implementation ClientMenuBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        _actions = [NSMutableArray array];
        _features = [NSMutableArray array];
    }
    return self;
}

- (void)registerAction:(NSString *)title callback:(JSValue *)callback {
    if (title.length == 0 || !callback || !callback.isObject) {
        ClientLoaderLog(@"ERROR: ignored invalid action registration");
        return;
    }
    NSIndexSet *existing = [self.actions indexesOfObjectsPassingTest:^BOOL(
        NSDictionary *item, __unused NSUInteger idx, __unused BOOL *stop) {
        return [item[@"title"] isEqualToString:title];
    }];
    if (existing.count) [self.actions removeObjectsAtIndexes:existing];
    [self.actions addObject:@{@"title": title, @"callback": callback}];
    ClientMenuRefresh();
}

- (void)registerFeature:(NSString *)title enabled:(BOOL)enabled callback:(JSValue *)callback {
    if (title.length == 0 || !callback || !callback.isObject) {
        ClientLoaderLog(@"ERROR: ignored invalid feature registration");
        return;
    }
    NSIndexSet *existing = [self.features indexesOfObjectsPassingTest:^BOOL(
        NSDictionary *item, __unused NSUInteger idx, __unused BOOL *stop) {
        return [item[@"title"] isEqualToString:title];
    }];
    if (existing.count) [self.features removeObjectsAtIndexes:existing];

    NSString *key = [kClientLoaderFeaturePrefix stringByAppendingString:title];
    id savedValue = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    BOOL currentValue = savedValue ? [savedValue boolValue] : enabled;
    NSMutableDictionary *record = [@{
        @"title": title,
        @"enabled": @(currentValue),
        @"callback": callback
    } mutableCopy];
    [self.features addObject:record];
    [callback callWithArguments:@[@(currentValue)]];
    ClientMenuRefresh();
}

- (BOOL)isFeatureEnabled:(NSString *)title {
    for (NSDictionary *feature in self.features) {
        if ([feature[@"title"] isEqualToString:title]) {
            return [feature[@"enabled"] boolValue];
        }
    }
    return NO;
}

- (void)setFeature:(NSString *)title enabled:(BOOL)enabled {
    for (NSMutableDictionary *feature in self.features) {
        if (![feature[@"title"] isEqualToString:title]) continue;
        feature[@"enabled"] = @(enabled);
        NSString *key = [kClientLoaderFeaturePrefix stringByAppendingString:title];
        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:key];
        JSValue *callback = feature[@"callback"];
        if (callback && !callback.isUndefined) {
            [callback callWithArguments:@[@(enabled)]];
        }
        return;
    }
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

@implementation ClientMenuPanel {
    __weak UIWindow *_hostWindow;
    __weak ClientMenuBridge *_bridge;
    UIView *_card;
    UISegmentedControl *_tabs;
    UIStackView *_rows;
}

- (instancetype)initWithWindow:(UIWindow *)window bridge:(ClientMenuBridge *)bridge {
    self = [super initWithFrame:window.bounds];
    if (!self) return nil;
    _hostWindow = window;
    _bridge = bridge;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.58];

    UIControl *dismissBackdrop = [[UIControl alloc] initWithFrame:self.bounds];
    dismissBackdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dismissBackdrop addTarget:self action:@selector(closePanel)
              forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:dismissBackdrop];

    _card = [UIView new];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.backgroundColor = ClientColor(@"#17151F", 0.98);
    _card.layer.cornerRadius = 22;
    _card.layer.borderWidth = 1;
    _card.layer.borderColor = ClientColor(kClientLoaderAccent, 0.52).CGColor;
    _card.layer.shadowColor = UIColor.blackColor.CGColor;
    _card.layer.shadowOpacity = 0.38;
    _card.layer.shadowRadius = 22;
    _card.layer.shadowOffset = CGSizeMake(0, 10);
    [self addSubview:_card];

    UILabel *title = [UILabel new];
    title.text = @"CLIENT";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:21 weight:UIFontWeightHeavy];
    UILabel *subtitle = [UILabel new];
    subtitle.text = @"BEDROCK  •  LOCAL TOOLS";
    subtitle.textColor = ClientColor(@"#AAA5B8", 1);
    subtitle.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    subtitle.numberOfLines = 1;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"×" forState:UIControlStateNormal];
    [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightRegular];
    close.backgroundColor = ClientColor(@"#302B3B", 1);
    close.layer.cornerRadius = 17;
    [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [close.widthAnchor constraintEqualToConstant:34],
        [close.heightAnchor constraintEqualToConstant:34]
    ]];

    UIStackView *headingText = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    headingText.axis = UILayoutConstraintAxisVertical;
    headingText.spacing = 1;
    UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[headingText, close]];
    heading.axis = UILayoutConstraintAxisHorizontal;
    heading.alignment = UIStackViewAlignmentCenter;
    heading.distribution = UIStackViewDistributionEqualSpacing;
    heading.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:heading];

    _tabs = [[UISegmentedControl alloc] initWithItems:@[@"Features", @"Buttons"]];
    _tabs.selectedSegmentIndex = 0;
    _tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [_tabs setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor}
                         forState:UIControlStateSelected];
    [_tabs setTitleTextAttributes:@{NSForegroundColorAttributeName: ClientColor(@"#C7C2D2", 1)}
                         forState:UIControlStateNormal];
    _tabs.selectedSegmentTintColor = ClientColor(kClientLoaderAccent, 1);
    _tabs.backgroundColor = ClientColor(@"#292532", 1);
    [_tabs addTarget:self action:@selector(tabChanged)
    forControlEvents:UIControlEventValueChanged];
    [_card addSubview:_tabs];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [_card addSubview:scroll];
    _rows = [UIStackView new];
    _rows.axis = UILayoutConstraintAxisVertical;
    _rows.spacing = 10;
    _rows.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:_rows];

    UILabel *footer = [UILabel new];
    footer.text = @"PERSONAL UI  •  NO WORLD EXPERIMENTS";
    footer.textColor = ClientColor(@"#8E899A", 1);
    footer.font = [UIFont systemFontOfSize:9 weight:UIFontWeightMedium];
    footer.textAlignment = NSTextAlignmentCenter;
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:footer];

    UILayoutGuide *safe = self.safeAreaLayoutGuide;
    NSLayoutConstraint *cardWidth =
        [_card.widthAnchor constraintEqualToAnchor:safe.widthAnchor multiplier:0.91];
    cardWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [_card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        cardWidth,
        [_card.widthAnchor constraintLessThanOrEqualToConstant:460],
        [_card.heightAnchor constraintEqualToAnchor:safe.heightAnchor multiplier:0.78],
        [heading.topAnchor constraintEqualToAnchor:_card.topAnchor constant:18],
        [heading.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:19],
        [heading.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-17],
        [_tabs.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:14],
        [_tabs.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:18],
        [_tabs.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-18],
        [_tabs.heightAnchor constraintEqualToConstant:36],
        [scroll.topAnchor constraintEqualToAnchor:_tabs.bottomAnchor constant:13],
        [scroll.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:17],
        [scroll.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-17],
        [scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-9],
        [footer.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:12],
        [footer.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-12],
        [footer.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-12],
        [_rows.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [_rows.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [_rows.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [_rows.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [_rows.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];
    [self reloadContent];
    return self;
}

- (void)closePanel {
    [UIView animateWithDuration:0.16 animations:^{ self.alpha = 0; }
                     completion:^(__unused BOOL finished) { [self removeFromSuperview]; }];
}

- (void)tabChanged {
    [self reloadContent];
}

- (UIView *)sectionLabel:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text.uppercaseString;
    label.textColor = ClientColor(kClientLoaderAccent, 1);
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    return label;
}

- (UIView *)noteLabel:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text;
    label.textColor = ClientColor(@"#B8B3C2", 1);
    label.font = [UIFont systemFontOfSize:12];
    label.numberOfLines = 0;
    return label;
}

- (UIView *)rowWithTitle:(NSString *)title detail:(NSString *)detail accessory:(UIView *)accessory {
    UIView *container = [UIView new];
    container.backgroundColor = ClientColor(@"#24212E", 1);
    container.layer.cornerRadius = 13;
    container.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *name = [UILabel new];
    name.text = title;
    name.textColor = UIColor.whiteColor;
    name.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    UILabel *description = [UILabel new];
    description.text = detail;
    description.textColor = ClientColor(@"#AAA5B8", 1);
    description.font = [UIFont systemFontOfSize:11];
    description.numberOfLines = 0;
    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[name, description]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 3;
    UIStackView *line = [[UIStackView alloc] initWithArrangedSubviews:@[labels, accessory]];
    line.axis = UILayoutConstraintAxisHorizontal;
    line.alignment = UIStackViewAlignmentCenter;
    line.spacing = 8;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:line];
    [accessory setContentHuggingPriority:UILayoutPriorityRequired
                                forAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [line.topAnchor constraintEqualToAnchor:container.topAnchor constant:11],
        [line.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-11],
        [line.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12],
        [line.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12],
        [container.heightAnchor constraintGreaterThanOrEqualToConstant:56]
    ]];
    return container;
}

- (UISwitch *)switchWithIdentifier:(NSString *)identifier isOn:(BOOL)isOn {
    UISwitch *toggle = [UISwitch new];
    toggle.on = isOn;
    toggle.onTintColor = ClientColor(kClientLoaderAccent, 1);
    toggle.accessibilityIdentifier = identifier;
    [toggle addTarget:self action:@selector(toggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    return toggle;
}

- (void)toggleChanged:(UISwitch *)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *identifier = sender.accessibilityIdentifier;
    if ([identifier isEqualToString:@"__haptics"]) {
        [defaults setBool:sender.isOn forKey:kClientLoaderHapticsKey];
    } else if ([identifier isEqualToString:@"__customButtons"]) {
        [defaults setBool:sender.isOn forKey:kClientLoaderButtonsVisibleKey];
        ClientLoaderRenderCustomButtons();
    } else {
        [_bridge setFeature:identifier enabled:sender.isOn];
    }
    if (ClientLoaderHapticsEnabled()) {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
}

- (UIButton *)actionButton:(NSString *)title action:(SEL)selector identifier:(NSString *)identifier {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    button.backgroundColor = ClientColor(kClientLoaderAccent, 0.78);
    button.layer.cornerRadius = 9;
    button.contentEdgeInsets = UIEdgeInsetsMake(7, 11, 7, 11);
    button.accessibilityIdentifier = identifier;
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)addCustomButtonTapped:(UIButton *)sender {
    NSString *title = sender.accessibilityIdentifier;
    if (title.length == 0) return;
    NSMutableArray<NSString *> *titles = [[NSUserDefaults.standardUserDefaults
        arrayForKey:kClientLoaderButtonTitlesKey] mutableCopy] ?: [NSMutableArray array];
    if (![titles containsObject:title]) [titles addObject:title];
    [NSUserDefaults.standardUserDefaults setObject:titles forKey:kClientLoaderButtonTitlesKey];
    ClientLoaderRenderCustomButtons();
    [self reloadContent];
}

- (void)removeCustomButtonTapped:(UIButton *)sender {
    NSString *title = sender.accessibilityIdentifier;
    NSMutableArray<NSString *> *titles = [[NSUserDefaults.standardUserDefaults
        arrayForKey:kClientLoaderButtonTitlesKey] mutableCopy] ?: [NSMutableArray array];
    [titles removeObject:title];
    [NSUserDefaults.standardUserDefaults setObject:titles forKey:kClientLoaderButtonTitlesKey];
    ClientLoaderRenderCustomButtons();
    [self reloadContent];
}

- (void)reloadContent {
    for (UIView *view in _rows.arrangedSubviews) {
        [_rows removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    if (_tabs.selectedSegmentIndex == 0) {
        [_rows addArrangedSubview:[self sectionLabel:@"Overlay"]];
        BOOL buttonsVisible = [NSUserDefaults.standardUserDefaults
            objectForKey:kClientLoaderButtonsVisibleKey]
            ? [NSUserDefaults.standardUserDefaults boolForKey:kClientLoaderButtonsVisibleKey]
            : YES;
        [_rows addArrangedSubview:[self rowWithTitle:@"Custom action buttons"
                                              detail:@"Show your added script actions over the game."
                                           accessory:[self switchWithIdentifier:@"__customButtons"
                                                                          isOn:buttonsVisible]]];
        BOOL haptics = [NSUserDefaults.standardUserDefaults
            objectForKey:kClientLoaderHapticsKey]
            ? [NSUserDefaults.standardUserDefaults boolForKey:kClientLoaderHapticsKey]
            : YES;
        [_rows addArrangedSubview:[self rowWithTitle:@"Haptic feedback"
                                              detail:@"Light vibration when changing a setting."
                                           accessory:[self switchWithIdentifier:@"__haptics"
                                                                          isOn:haptics]]];

        [_rows addArrangedSubview:[self sectionLabel:@"Script features"]];
        if (_bridge.features.count == 0) {
            [_rows addArrangedSubview:[self noteLabel:
                @"No script features registered. Add a feature in a local .js file to expose its toggle here."]];
        }
        for (NSDictionary *feature in _bridge.features) {
            NSString *title = feature[@"title"];
            [_rows addArrangedSubview:[self rowWithTitle:title
                                                  detail:@"Runs the local script callback when changed."
                                               accessory:[self switchWithIdentifier:title
                                                                              isOn:[feature[@"enabled"] boolValue]]]];
        }
    } else {
        [_rows addArrangedSubview:[self sectionLabel:@"Available actions"]];
        [_rows addArrangedSubview:[self noteLabel:
            @"Add an action as a floating on-screen button. Actions come from trusted local scripts."]];
        NSArray<NSString *> *added = [NSUserDefaults.standardUserDefaults
            arrayForKey:kClientLoaderButtonTitlesKey] ?: @[];
        if (_bridge.actions.count == 0) {
            [_rows addArrangedSubview:[self noteLabel:
                @"No script actions registered. Put .js files in Documents/ClientLoader/scripts/."]];
        }
        for (NSDictionary *action in _bridge.actions) {
            NSString *title = action[@"title"];
            BOOL isAdded = [added containsObject:title];
            UIButton *add = [self actionButton:(isAdded ? @"Added" : @"Add")
                                         action:@selector(addCustomButtonTapped:)
                                     identifier:title];
            add.enabled = !isAdded;
            if (isAdded) add.backgroundColor = ClientColor(@"#514B5B", 1);
            [_rows addArrangedSubview:[self rowWithTitle:title
                                                  detail:@"Creates a quick button for this script action."
                                               accessory:add]];
        }

        [_rows addArrangedSubview:[self sectionLabel:@"Your buttons"]];
        if (added.count == 0) {
            [_rows addArrangedSubview:[self noteLabel:@"No custom buttons yet."]];
        }
        for (NSString *title in added) {
            UIButton *remove = [self actionButton:@"Remove"
                                           action:@selector(removeCustomButtonTapped:)
                                       identifier:title];
            remove.backgroundColor = ClientColor(@"#8A435E", 1);
            [_rows addArrangedSubview:[self rowWithTitle:title
                                                  detail:@"Pinned to the game overlay."
                                               accessory:remove]];
        }
    }
}

@end

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
    return nil;
}

static void ClientMenuOpen(void) {
    if (!sBridge.window) {
        ClientLoaderLog(@"ERROR: menu open requested before an active window was available");
        return;
    }
    if (sMenuPanel.superview) {
        ClientLoaderLog(@"Closing client panel");
        [sMenuPanel removeFromSuperview];
        sMenuPanel = nil;
        return;
    }
    ClientLoaderLog(@"Opening client panel");
    @try {
        ClientMenuPanel *panel = [[ClientMenuPanel alloc]
            initWithWindow:sBridge.window bridge:sBridge];
        panel.alpha = 0;
        [sBridge.window addSubview:panel];
        [sBridge.window bringSubviewToFront:panel];
        sMenuPanel = panel;
        ClientLoaderLog(@"Opened client panel");
        [UIView animateWithDuration:0.18 animations:^{ panel.alpha = 1; }];
    } @catch (NSException *exception) {
        sMenuPanel = nil;
        ClientLoaderLog([NSString stringWithFormat:
            @"ERROR: could not open client panel (%@): %@\nCall stack:\n%@",
            exception.name, exception.reason ?: @"(no reason)",
            [exception.callStackSymbols componentsJoinedByString:@"\n"]]);
    }
}

static void ClientMenuRefresh(void) {
    if (sMenuPanel.superview) [sMenuPanel reloadContent];
    ClientLoaderRenderCustomButtons();
}

static void ClientLoaderSaveMenuButtonPosition(void) {
    UIWindow *window = sBridge.window;
    if (!window || CGRectGetWidth(window.bounds) <= 0 || CGRectGetHeight(window.bounds) <= 0) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:sMenuButton.center.x / CGRectGetWidth(window.bounds)
                 forKey:kClientLoaderButtonXKey];
    [defaults setDouble:sMenuButton.center.y / CGRectGetHeight(window.bounds)
                 forKey:kClientLoaderButtonYKey];
}

static void ClientLoaderClampButton(UIButton *button, UIWindow *window) {
    CGFloat radius = CGRectGetWidth(button.bounds) / 2.0;
    CGFloat minX = radius + 4;
    CGFloat maxX = MAX(minX, CGRectGetWidth(window.bounds) - radius - 4);
    CGFloat minY = radius + window.safeAreaInsets.top + 4;
    CGFloat maxY = MAX(minY, CGRectGetHeight(window.bounds) - radius - window.safeAreaInsets.bottom - 4);
    button.center = CGPointMake(MIN(MAX(button.center.x, minX), maxX),
                                MIN(MAX(button.center.y, minY), maxY));
}

static void ClientLoaderRenderCustomButtons(void) {
    UIWindow *window = sBridge.window;
    if (!window) return;
    [sCustomButtonStack removeFromSuperview];
    sCustomButtonStack = nil;
    BOOL visible = [NSUserDefaults.standardUserDefaults
        objectForKey:kClientLoaderButtonsVisibleKey]
        ? [NSUserDefaults.standardUserDefaults boolForKey:kClientLoaderButtonsVisibleKey]
        : YES;
    if (!visible) return;

    NSArray<NSString *> *titles = [NSUserDefaults.standardUserDefaults
        arrayForKey:kClientLoaderButtonTitlesKey] ?: @[];
    if (titles.count == 0) return;

    sCustomButtonStack = [UIStackView new];
    sCustomButtonStack.axis = UILayoutConstraintAxisVertical;
    sCustomButtonStack.alignment = UIStackViewAlignmentLeading;
    sCustomButtonStack.spacing = 8;
    sCustomButtonStack.translatesAutoresizingMaskIntoConstraints = NO;
    [window addSubview:sCustomButtonStack];
    [NSLayoutConstraint activateConstraints:@[
        [sCustomButtonStack.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:12],
        [sCustomButtonStack.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-92],
        [sCustomButtonStack.widthAnchor constraintLessThanOrEqualToAnchor:window.widthAnchor multiplier:0.58]
    ]];

    for (NSString *title in titles) {
        NSDictionary *action = nil;
        for (NSDictionary *candidate in sBridge.actions) {
            if ([candidate[@"title"] isEqualToString:title]) {
                action = candidate;
                break;
            }
        }
        if (!action) continue;
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:title forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        button.backgroundColor = ClientColor(@"#24212E", 0.94);
        button.layer.cornerRadius = 15;
        button.layer.borderWidth = 1;
        button.layer.borderColor = ClientColor(kClientLoaderAccent, 0.84).CGColor;
        button.contentEdgeInsets = UIEdgeInsetsMake(9, 13, 9, 13);
        button.accessibilityIdentifier = title;
        [button addTarget:sTarget action:@selector(runCustomAction:)
         forControlEvents:UIControlEventTouchUpInside];
        [sCustomButtonStack addArrangedSubview:button];
    }
}

@implementation ClientDraggableButton

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *touch = touches.anyObject;
    UIWindow *window = self.window;
    if (!touch || !window) return;
    self.touchStart = [touch locationInView:window];
    self.initialCenter = self.center;
    self.didMove = NO;
    self.alpha = 0.82;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *touch = touches.anyObject;
    UIWindow *window = self.window;
    if (!touch || !window) return;
    CGPoint location = [touch locationInView:window];
    CGFloat dx = location.x - self.touchStart.x;
    CGFloat dy = location.y - self.touchStart.y;
    if (!self.didMove && hypot(dx, dy) < 8.0) return;
    self.didMove = YES;
    self.center = CGPointMake(self.initialCenter.x + dx, self.initialCenter.y + dy);
    ClientLoaderClampButton(self, window);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    self.alpha = 1.0;
    if (self.didMove) {
        ClientLoaderSaveMenuButtonPosition();
    } else {
        ClientMenuOpen();
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    self.alpha = 1.0;
    if (self.didMove) ClientLoaderSaveMenuButtonPosition();
}

@end

static void ClientLoaderInstallButton(UIWindow *window) {
    sBridge.window = window;
    if (sMenuButton && sMenuButton.superview == window) {
        ClientLoaderClampButton(sMenuButton, window);
        ClientLoaderRenderCustomButtons();
        return;
    }
    [sMenuButton removeFromSuperview];
    CGFloat side = 54.0;
    sMenuButton = [ClientDraggableButton buttonWithType:UIButtonTypeSystem];
    sMenuButton.bounds = CGRectMake(0, 0, side, side);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    double savedX = [defaults doubleForKey:kClientLoaderButtonXKey];
    double savedY = [defaults doubleForKey:kClientLoaderButtonYKey];
    CGFloat x = savedX > 0 ? savedX * CGRectGetWidth(window.bounds) : CGRectGetWidth(window.bounds) - side / 2.0 - 16.0;
    CGFloat y = savedY > 0 ? savedY * CGRectGetHeight(window.bounds) : CGRectGetHeight(window.bounds) * 0.70;
    sMenuButton.center = CGPointMake(x, y);
    sMenuButton.backgroundColor = ClientColor(kClientLoaderAccent, 0.96);
    sMenuButton.layer.cornerRadius = side / 2.0;
    sMenuButton.layer.borderWidth = 1.5;
    sMenuButton.layer.borderColor = UIColor.whiteColor.CGColor;
    sMenuButton.layer.shadowColor = UIColor.blackColor.CGColor;
    sMenuButton.layer.shadowOpacity = 0.35;
    sMenuButton.layer.shadowRadius = 7;
    sMenuButton.layer.shadowOffset = CGSizeMake(0, 3);
    [sMenuButton setTitle:@"C" forState:UIControlStateNormal];
    [sMenuButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    sMenuButton.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightHeavy];
    sMenuButton.userInteractionEnabled = YES;
    sMenuButton.multipleTouchEnabled = NO;
    sMenuButton.exclusiveTouch = YES;
    sMenuButton.accessibilityLabel = @"Drag or open Client Menu";
    sMenuButton.accessibilityHint = @"Drag to move; tap to open the client panel";
    if (!sTarget) sTarget = [ClientLoaderTarget new];
    [window addSubview:sMenuButton];
    ClientLoaderClampButton(sMenuButton, window);
    ClientLoaderRenderCustomButtons();
    ClientLoaderLog([NSString stringWithFormat:
        @"Installed draggable menu button at %@",
        NSStringFromCGPoint(sMenuButton.center)]);
}

@implementation ClientLoaderTarget

- (void)runCustomAction:(UIButton *)sender {
    NSString *title = sender.accessibilityIdentifier;
    for (NSDictionary *action in sBridge.actions) {
        if (![action[@"title"] isEqualToString:title]) continue;
        JSValue *callback = action[@"callback"];
        if (callback && !callback.isUndefined) [callback callWithArguments:@[]];
        if (ClientLoaderHapticsEnabled()) {
            UIImpactFeedbackGenerator *feedback =
                [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [feedback impactOccurred];
        }
        return;
    }
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
        ClientLoaderLog([NSString stringWithFormat:
            @"ERROR: could not create script directory: %@", directoryError]);
        return;
    }
    sScriptsLoaded = YES;

    sBridge = [ClientMenuBridge new];
    sContext = [JSContext new];
    sBridge.context = sContext;
    sContext[@"ClientMenu"] = sBridge;
    sContext.exceptionHandler = ^(JSContext *context, JSValue *exception) {
        ClientLoaderLog([NSString stringWithFormat:
            @"ERROR: JavaScript exception: %@", exception]);
    };

    NSError *listingError = nil;
    NSArray<NSURL *> *items = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:scriptDirectory
       includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                          options:NSDirectoryEnumerationSkipsHiddenFiles
                            error:&listingError];
    if (!items) {
        ClientLoaderLog([NSString stringWithFormat:
            @"ERROR: could not list scripts: %@", listingError]);
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
            ClientLoaderLog([NSString stringWithFormat:
                @"ERROR: could not read script %@: %@",
                scriptURL.lastPathComponent, readError]);
            continue;
        }
        [sContext evaluateScript:source withSourceURL:scriptURL];
    }
    ClientLoaderLog([NSString stringWithFormat:
        @"Loaded %lu JavaScript file(s) from %@",
        (unsigned long)scripts.count, scriptDirectory.path]);
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
        ClientLoaderLog(@"ERROR: gave up waiting for an active app window");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{ ClientLoaderStart(); });
}

__attribute__((constructor))
static void ClientLoaderInitialize(void) {
    @autoreleasepool {
        sLogLock = [NSObject new];
        sPreviousUncaughtExceptionHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&ClientLoaderHandleUncaughtException);
        ClientLoaderLog(@"Native loader initialized");
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
