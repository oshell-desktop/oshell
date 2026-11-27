// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation

/// Both apps consume the same generated field contract. Unsupported data is
/// rejected before Codable can silently discard it. Error text contains no values.
public enum SharedConfigurationProtocol {
    public static var contractData: Data { Data(sharedConfigurationContract.utf8) }
    private static let definitions = (try! JSONSerialization.jsonObject(with: contractData) as! [String: Any])["definitions"] as! [String: [String: [String: Any]]]
    private static func failure(_ path: String) -> Error { ModelError.invalid("共享配置协议字段不支持或类型无效：\(path)；请升级所有节点后重试，未覆盖数据") }
    public static func canonicalData(_ data: Data) throws -> Data {try canonical(data,rootType:"configuration")}
    public static func canonicalAppearanceData(_ data: Data) throws -> Data { try canonical(data, rootType: "terminalAppearance") }
    public static func canonicalArchiveData(_ data:Data)throws->Data {try canonical(data,rootType:"archive")}
    private static func canonical(_ data:Data,rootType:String)throws->Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("configuration") }
        migrate(&root)
        let result = try normalize(root, rule: ["type":"object", "ref":rootType], path:rootType)
        return try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
    }
    private static func normalize(_ value: Any, rule: [String: Any], path: String) throws -> Any {
        if value is NSNull, rule["nullable"] as? Bool == true { return NSNull() }
        switch rule["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else {throw failure(path)}
            var output = [String: Any]()
            if let itemRule = rule["mapOf"] as? [String: Any] {
                for (key,item) in object {if let keys=rule["keys"] as? [String], !keys.contains(key) {throw failure(path+".[unknown]")};output[key] = try normalize(item,rule:itemRule,path:path+".*")};return output
            }
            guard let ref = rule["ref"] as? String, let fields = definitions[ref] else {throw failure(path)}
            for key in object.keys where fields[key] == nil {throw failure(path+".[unknown]")}
            let marker = ref == "proxy" && object["kind"] as? String == "shared-reference"
            for (key,field) in fields {
                if marker && key != "id" && key != "kind" {if object[key] != nil {throw failure(path+"."+key)};continue}
                var item = object[key]
                if item == nil || (item is NSNull && field["nullable"] as? Bool != true) {
                    if field["required"] as? Bool == true {throw failure(path+"."+key)}
                    item = field["default"]
                }
                guard let item else {continue}
                output[key] = try normalize(item,rule:field,path:path+"."+key)
            }
            return output
        case "array":
            guard let array = value as? [Any], let item = rule["items"] as? [String:Any] else {throw failure(path)}
            if let minimum=rule["minItems"] as? Int, array.count<minimum {throw failure(path)}
            if let maximum=rule["maxItems"] as? Int, array.count>maximum {throw failure(path)}
            return try array.map {try normalize($0,rule:item,path:path+"[]")}
        case "string":
            guard let string=value as? String else {throw failure(path)}
            if let pattern=rule["pattern"] as? String, string.range(of:pattern,options:.regularExpression)==nil {throw failure(path)}
        case "boolean":
            guard let number=value as? NSNumber, CFGetTypeID(number)==CFBooleanGetTypeID() else {throw failure(path)}
        case "integer", "number":
            guard let number=value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {throw failure(path)}
            let n=number.doubleValue
            if rule["type"] as? String == "integer", (n.rounded(.towardZero) != n || abs(n)>9007199254740991) {throw failure(path)}
            if let minimum=rule["minimum"] as? Double,n<minimum {throw failure(path)}
            if let maximum=rule["maximum"] as? Double,n>maximum {throw failure(path)}
        default: throw failure(path)
        }
        if let values=rule["values"] as? [Any] {
            let candidate=try JSONSerialization.data(withJSONObject:[value],options:.sortedKeys)
            guard try values.contains(where:{try JSONSerialization.data(withJSONObject:[$0],options:.sortedKeys)==candidate}) else {throw failure(path)}
        }
        return value
    }
    private static func migrate(_ root: inout [String:Any]) {
        if var prefs=root["preferences"] as? [String:Any] {
            if let scope=prefs["quickSendScope"] as? String, let index=["current","tab","all","visible","selected","currentGroup","selectedGroups"].firstIndex(of:scope) {prefs["quickSendScope"]=index}
            root["preferences"]=prefs
        }
        if var profiles=root["profiles"] as? [[String:Any]] {
            for i in profiles.indices {
                if (profiles[i]["titleMode"]==nil || profiles[i]["titleMode"] is NSNull), let old=profiles[i]["activeHostProbe"] as? NSNumber, CFGetTypeID(old)==CFBooleanGetTypeID(), old.boolValue {profiles[i]["titleMode"]="activeProbe"}
                if let old=profiles[i]["activeHostProbe"] as? NSNumber, CFGetTypeID(old)==CFBooleanGetTypeID() {profiles[i].removeValue(forKey:"activeHostProbe")}
                if (profiles[i]["initialDirectory"]==nil || profiles[i]["initialDirectory"] is NSNull), profiles[i]["kind"] as? String == "ftp" {profiles[i]["initialDirectory"]="/"}
                if (profiles[i]["proxy"]==nil || profiles[i]["proxy"] is NSNull), let id=profiles[i]["id"] as? String {
                    var digest=Array(PlatformDigest.sha256(Data(("OShell absent proxy v1\n"+id.uppercased()).utf8)))
                    digest[6]=(digest[6]&15)|0x50;digest[8]=(digest[8]&63)|0x80
                    let hex=digest.prefix(16).map{String(format:"%02x",$0)}.joined()
                    let chars=Array(hex);let uuid=[String(chars[0..<8]),String(chars[8..<12]),String(chars[12..<16]),String(chars[16..<20]),String(chars[20..<32])].joined(separator:"-")
                    profiles[i]["proxy"]=["id":uuid,"kind":"none"]
                }
            }
            root["profiles"]=profiles
        }
    }
}
