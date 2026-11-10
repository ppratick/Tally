import Foundation
import Security

struct WidgetAccount: Codable, Identifiable, Sendable {
    let id: String
    let bank: String
    var name: String
    let mask: String
    let isCredit: Bool
    let currency: String
    let balance: Double?
    var shortBank: String { bank.localizedCaseInsensitiveContains("America") ? "BofA" : bank }
}
struct WidgetSnapshot: Codable, Sendable {
    let date: String
    var accounts: [WidgetAccount]
    var cash: Double { accounts.filter { !$0.isCredit && $0.currency == "USD" }.compactMap(\.balance).reduce(0,+) }
    var debt: Double { accounts.filter { $0.isCredit && $0.currency == "USD" }.compactMap(\.balance).reduce(0,+) }
    var net: Double { cash - debt }
    var updatedDate: Date? {
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return formatter.date(from:date) ?? ISO8601DateFormatter().date(from:date)
    }
}
struct WidgetPreferences: Codable, Sendable {
    var server: String
    var token: String
    var order: [String]
    var hidden: [String]
    var names: [String:String]
    func applying(to snapshot:WidgetSnapshot) -> WidgetSnapshot {
        var result=snapshot
        result.accounts=snapshot.accounts.filter { !hidden.contains($0.id) }.map { original in
            var account=original
            if let name=names[account.id],!name.isEmpty { account.name=name }
            return account
        }.sorted { (order.firstIndex(of:$0.id) ?? Int.max) < (order.firstIndex(of:$1.id) ?? Int.max) }
        return result
    }
}
enum WidgetStorage {
    private static let service="com.pratick.Tally.widget"
    private static var group: String? { Bundle.main.object(forInfoDictionaryKey:"TallyKeychainGroup") as? String }
    static func read<T:Decodable>(_ key:String,as:T.Type) -> T? {
        guard let group,!group.contains("$(") else { return nil }
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:key,
            kSecAttrAccessGroup as String:group,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,let data=result as? Data else{return nil}
        return try? JSONDecoder().decode(T.self,from:data)
    }
    @discardableResult static func save<T:Encodable>(_ value:T,key:String) -> Bool {
        guard let group,!group.contains("$("),let data=try? JSONEncoder().encode(value) else{return false}
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:key,kSecAttrAccessGroup as String:group]
        let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecItemNotFound {
            var add=query;add[kSecValueData as String]=data
            add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary,nil)==errSecSuccess
        }
        return status==errSecSuccess
    }
}
