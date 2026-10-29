import Foundation
import ServiceKit

public enum Credentials {
    public static func loadOrCreate() throws -> String { try ServiceCredentials.loadOrCreate(service: "local.RemoteAgent") }
}
