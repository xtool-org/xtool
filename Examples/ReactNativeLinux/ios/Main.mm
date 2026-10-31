#import <UIKit/UIKit.h>
#import <React/RCTBridge.h>
#import <React/RCTBridgeDelegate.h>
#import <React/RCTRootView.h>
#import <React/RCTLog.h>
#import <os/log.h>

@interface ReactAppDelegate : UIResponder <UIApplicationDelegate, RCTBridgeDelegate>
@property(nonatomic, strong) RCTBridge *bridge;
@property(nonatomic, strong) UIWindow *window;
@end

@interface ReactSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ReactAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    RCTSetLogFunction(^(RCTLogLevel level, RCTLogSource source, NSString *file, NSNumber *line, NSString *message) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "[OmarchyRN] %{public}s", message.UTF8String);
    });
    [[NSNotificationCenter defaultCenter] addObserverForName:RCTJavaScriptDidLoadNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *notification) {
            NSLog(@"[OmarchyRN] JavaScript bundle loaded by React Native");
        }];
    self.bridge = [[RCTBridge alloc] initWithDelegate:self launchOptions:options];
    return YES;
}
- (NSURL *)sourceURLForBridge:(RCTBridge *)bridge {
    return [[NSBundle mainBundle] URLForResource:@"main" withExtension:@"jsbundle"];
}
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session
    options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc]
        initWithName:@"React Native" sessionRole:session.role];
    configuration.delegateClass = [ReactSceneDelegate class];
    return configuration;
}
@end

@implementation ReactSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    ReactAppDelegate *delegate = (ReactAppDelegate *)UIApplication.sharedApplication.delegate;
    RCTRootView *root = [[RCTRootView alloc] initWithBridge:delegate.bridge
        moduleName:@"OmarchyReactNative" initialProperties:nil];
    root.backgroundColor = UIColor.systemBackgroundColor;
    UIViewController *controller = [UIViewController new];
    controller.view = root;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    delegate.window = self.window;
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    NSLog(@"[OmarchyRN] RCTRootView attached to iPhone window");
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([ReactAppDelegate class]));
    }
}
