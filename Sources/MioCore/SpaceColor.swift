import Foundation

/// Device-independent, opaque sRGB storage shared by every space renderer.
public struct MioSpaceRGB: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public init(red: Double, green: Double, blue: Double) {
        func clamp(_ x: Double) -> Double { x.isFinite ? min(1,max(0,x)):0 }
        self.red=clamp(red);self.green=clamp(green);self.blue=clamp(blue)
    }
    public init?(hex: String) {
        guard hex.count==7,hex.first=="#",hex.dropFirst().allSatisfy({"0123456789abcdefABCDEF".contains($0)}),let value=UInt32(hex.dropFirst(),radix:16) else { return nil }
        self.init(red:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255)
    }
    public var hex: String { String(format:"#%02X%02X%02X",Int((red*255).rounded()),Int((green*255).rounded()),Int((blue*255).rounded())) }
}
