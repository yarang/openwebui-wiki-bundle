// vision-ocr — Apple Vision 기반 OCR 헬퍼 (완전 오프라인, macOS 내장 엔진 사용).
//
// 사용법:  vision-ocr <file.pdf | image>
//   - PDF: PDFKit으로 각 페이지를 이미지로 렌더 → Vision OCR (스캔 PDF 대응)
//   - 이미지(png/jpg/…): 바로 Vision OCR
// 출력: 인식 텍스트(표준출력), 페이지는 빈 줄로 구분.
//
// macOS 12+ 의 OS 내장 Swift 런타임/Vision/PDFKit만 사용 → 대상 Mac에 Xcode 불필요.
import Foundation
import Vision
import AppKit
import PDFKit

let RENDER_SCALE: CGFloat = 2.78  // ~200 dpi (72pt 기준)
let LANGS = ["ko-KR", "en-US"]

func ocrCGImage(_ cg: CGImage) -> String {
    var lines: [String] = []
    let req = VNRecognizeTextRequest { request, _ in
        guard let obs = request.results as? [VNRecognizedTextObservation] else { return }
        for o in obs {
            if let c = o.topCandidates(1).first { lines.append(c.string) }
        }
    }
    req.recognitionLevel = .accurate
    req.recognitionLanguages = LANGS
    req.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    try? handler.perform([req])
    return lines.joined(separator: "\n")
}

func renderPage(_ page: PDFPage) -> CGImage? {
    let rect = page.bounds(for: .mediaBox)
    let w = Int(rect.width * RENDER_SCALE)
    let h = Int(rect.height * RENDER_SCALE)
    guard w > 0, h > 0,
          let ctx = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: RENDER_SCALE, y: RENDER_SCALE)
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: vision-ocr <file.pdf|image>\n".data(using: .utf8)!)
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
let ext = url.pathExtension.lowercased()

if ext == "pdf" {
    guard let doc = PDFDocument(url: url) else {
        FileHandle.standardError.write("PDF 열기 실패\n".data(using: .utf8)!)
        exit(1)
    }
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i), let cg = renderPage(page) else { continue }
        let text = ocrCGImage(cg)
        if !text.isEmpty { print(text) }
        if i < doc.pageCount - 1 { print("") }
    }
} else {
    guard let img = NSImage(contentsOf: url),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("이미지 열기 실패\n".data(using: .utf8)!)
        exit(1)
    }
    print(ocrCGImage(cg))
}
