// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct TerminalAppearance: Codable, Equatable {
    public var top = 5, bottom = 5, left = 5, right = 5
    public var lineSpacing = 0, characterSpacing = 0
    public var cursorShape = "block", cursorBlink = false, blinkInterval = 600
    public var boldStyle = "both", asianFont = "", asianSize = 0
    public var fontWeight = 400, asianWeight = 0, allowProportional = true
    public var fontQuality = "system", tabColor = "", imagePosition = "center"

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        try SharedConfigurationProtocol.validateFieldNames(from: decoder, definition: "terminalAppearance")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        top = try values.decodeIfPresent(Int.self, forKey: .top) ?? top
        bottom = try values.decodeIfPresent(Int.self, forKey: .bottom) ?? bottom
        left = try values.decodeIfPresent(Int.self, forKey: .left) ?? left
        right = try values.decodeIfPresent(Int.self, forKey: .right) ?? right
        lineSpacing = try values.decodeIfPresent(Int.self, forKey: .lineSpacing) ?? lineSpacing
        characterSpacing = try values.decodeIfPresent(Int.self, forKey: .characterSpacing) ?? characterSpacing
        blinkInterval = try values.decodeIfPresent(Int.self, forKey: .blinkInterval) ?? blinkInterval
        asianSize = try values.decodeIfPresent(Int.self, forKey: .asianSize) ?? asianSize
        fontWeight = try values.decodeIfPresent(Int.self, forKey: .fontWeight) ?? fontWeight
        asianWeight = try values.decodeIfPresent(Int.self, forKey: .asianWeight) ?? asianWeight
        cursorShape = try values.decodeIfPresent(String.self, forKey: .cursorShape) ?? cursorShape
        boldStyle = try values.decodeIfPresent(String.self, forKey: .boldStyle) ?? boldStyle
        asianFont = try values.decodeIfPresent(String.self, forKey: .asianFont) ?? asianFont
        fontQuality = try values.decodeIfPresent(String.self, forKey: .fontQuality) ?? fontQuality
        tabColor = try values.decodeIfPresent(String.self, forKey: .tabColor) ?? tabColor
        imagePosition = try values.decodeIfPresent(String.self, forKey: .imagePosition) ?? imagePosition
        cursorBlink = try values.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? cursorBlink
        allowProportional = try values.decodeIfPresent(Bool.self, forKey: .allowProportional) ?? allowProportional
        try validate()
    }

    public func validate() throws {
        _ = try SharedConfigurationProtocol.canonicalAppearanceData(JSONEncoder().encode(self))
    }
}
