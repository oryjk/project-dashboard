import AppKit

// 渲染 1024x1024 应用图标：渐变圆角方块 + 三条状态行（彩色圆点 + 文字占位条）
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.set()
canvas.fill()

// 背景：macOS 风格圆角矩形 + 竖向渐变
let bgRect = canvas.insetBy(dx: 22, dy: 22)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 234, yRadius: 234)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.49, green: 0.42, blue: 1.00, alpha: 1), // 顶部亮紫
    ending: NSColor(calibratedRed: 0.28, green: 0.20, blue: 0.78, alpha: 1)     // 底部深紫
)!
gradient.draw(in: bgPath, angle: -90)

// 三条状态行
let rowWidth: CGFloat = 720
let rowHeight: CGFloat = 150
let rowX = (size - rowWidth) / 2
let spacing: CGFloat = 90
let blockHeight = rowHeight * 3 + spacing * 2
var y = (size - blockHeight) / 2  // 最下面一行的 y

let dotColors = [
    NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.35, alpha: 1), // 绿：干净
    NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.04, alpha: 1), // 橙：未提交
    NSColor(calibratedRed: 0.39, green: 0.82, blue: 1.00, alpha: 1), // 蓝：未推送
]

for i in 0..<3 {
    let rowRect = NSRect(x: rowX, y: y, width: rowWidth, height: rowHeight)
    let rowPath = NSBezierPath(roundedRect: rowRect, xRadius: 38, yRadius: 38)
    NSColor.white.withAlphaComponent(0.94).set()
    rowPath.fill()

    // 状态圆点
    let dotDiameter: CGFloat = 62
    let dotRect = NSRect(x: rowX + 50,
                         y: y + (rowHeight - dotDiameter) / 2,
                         width: dotDiameter, height: dotDiameter)
    dotColors[i].set()
    NSBezierPath(ovalIn: dotRect).fill()

    // 文字占位条
    let lineRect = NSRect(x: rowX + 150,
                          y: y + (rowHeight - 38) / 2,
                          width: 330, height: 38)
    NSColor.black.withAlphaComponent(0.16).set()
    NSBezierPath(roundedRect: lineRect, xRadius: 19, yRadius: 19).fill()

    y += rowHeight + spacing
}

image.unlockFocus()

// 写出 PNG
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG 导出失败")
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets/AppIcon.png"
try FileManager.default.createDirectory(at: URL(fileURLWithPath: outPath).deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try png.write(to: URL(fileURLWithPath: outPath))
print("已生成 \(outPath)")
