import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let side = 1024
let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.025, green: 0.38, blue: 0.37, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
context.setStrokeColor(CGColor(red: 0.8, green: 0.96, blue: 0.83, alpha: 1)); context.setLineCap(.round); context.setLineWidth(52)
for (i,height) in [140, 310, 480, 310, 140].enumerated() {
    let x = 240 + i * 136
    context.move(to: CGPoint(x: x, y: 480-height/2)); context.addLine(to: CGPoint(x: x, y: 480+height/2)); context.strokePath()
}
context.setFillColor(CGColor(red: 0.67, green: 0.89, blue: 0.44, alpha: 1)); context.fillEllipse(in: CGRect(x: 660, y: 780, width: 130, height: 68))
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil); guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write icon") }
