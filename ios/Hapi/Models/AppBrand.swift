import Foundation
import SwiftUI

/// Compile-time app identity separating personal HAPI (`com.sagewe.hapi`) from
/// the standalone 「琪琪工作」 (`com.sagewe.qiqiwork`) iOS build.
enum AppBrand {
    #if QIQI_WORK_STANDALONE
    static let isQiqiWork = true
    static let displayName = "琪琪工作"
    static let loggerSubsystem = "com.sagewe.qiqiwork"
    static let pushKeychainService = "com.sagewe.qiqiwork.push"
    static let pairingIcon = "checkmark.shield.fill"
    static let showsSetupGuideLink = false
    static let pairingTitle = "连接合规工作台"
    static let addHubTitle = "添加工作台"
    static let pairingIntro: LocalizedStringKey = "琪琪工作是独立合规调查工作台。请扫描合规工作台配对二维码，或手动输入服务地址与访问码完成连接。"
    #else
    static let isQiqiWork = false
    static let displayName = "HAPI"
    static let loggerSubsystem = "run.hapi.companion"
    static let pushKeychainService = "run.hapi.companion.push"
    static let pairingIcon = "antenna.radiowaves.left.and.right"
    static let showsSetupGuideLink = true
    static let pairingTitle = String(localized: "Pair with your hub")
    static let addHubTitle = String(localized: "Add another hub")
    static var pairingIntro: LocalizedStringKey {
        #if targetEnvironment(macCatalyst)
        "HAPI is self-hosted: your agent sessions run on your own machine, served by a hub you operate. Start the hub, then enter its URL and access token, or paste the pairing link it prints."
        #else
        "HAPI is self-hosted: your agent sessions run on your own machine, served by a hub you operate. Start the hub on your computer, then pair this app with the QR code it prints — or enter the hub URL and access token by hand."
        #endif
    }
    #endif
}
