import Foundation

/// Text decoding by MIME charset name, falling back to UTF-8 and then Windows-1252.
public enum Charset {
    public static func encoding(named name: String?) -> String.Encoding? {
        guard var name = name?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased(), !name.isEmpty else {
            return nil
        }
        // Common mislabels.
        if name == "utf8" {
            name = "utf-8"
        }
        if name == "ascii" || name == "us-ascii" {
            return .utf8
        }
        if name == "latin1" {
            name = "iso-8859-1"
        }
        if name == "ks_c_5601-1987" {
            name = "euc-kr"
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    public static func decode(_ data: Data, charset: String?) -> String {
        if let encoding = encoding(named: charset), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }
}
