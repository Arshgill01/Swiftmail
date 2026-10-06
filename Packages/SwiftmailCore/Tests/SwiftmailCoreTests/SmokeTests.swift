@testable import SwiftmailCore
import Testing

@Test func appSupportFolderName() {
    #expect(SwiftmailCore.appSupportFolderName == "Swiftmail")
}
