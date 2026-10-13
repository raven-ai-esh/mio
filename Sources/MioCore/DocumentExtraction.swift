import Foundation
import AppKit
import PDFKit
import Vision
import ImageIO
import UniformTypeIdentifiers

public enum MioDocumentExtraction {
    public static let version = "native-pdfkit-vision-v3"
    public static func textChunks(_ text: String, maximum: Int = 2200) -> [(String, Int, Int)] {
        let ns=text as NSString
        var chunks:[(String,Int,Int)]=[],offset=0
        while offset<ns.length {
            var length=min(maximum,ns.length-offset)
            if offset+length<ns.length {
                let range=ns.range(of:"\n",options:.backwards,range:NSRange(location:offset,length:length))
                if range.location != NSNotFound,range.location-offset>maximum/2 { length=range.location-offset+1 }
            }
            let range=ns.rangeOfComposedCharacterSequences(for:NSRange(location:offset,length:length))
            let value=ns.substring(with:range)
            if !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { chunks.append((value,range.location,range.length)) }
            offset=NSMaxRange(range)
        }
        return chunks
    }
    public static func fragments(file: JSONValue, bytes: Data) throws -> [JSONValue] {
        var results:[JSONValue]=[]
        if file["mime_type"] == .string("application/pdf") {
            guard let document=PDFDocument(data:bytes),!document.isLocked,document.pageCount>0 else { throw MioError("invalid_file","PDF cannot be extracted") }
            for index in 0..<document.pageCount {
                guard let page=document.page(at:index) else { throw MioError("invalid_file","A PDF page is unavailable") }
                let locator:[String:JSONValue] = ["page":.number(Double(index+1))]
                let text=page.string ?? ""
                if !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    for (chunk,start,length) in textChunks(text) {
                        var position=locator;position["utf16_start"] = .number(Double(start));position["utf16_length"] = .number(Double(length));position["text_method"] = .string("pdf_text")
                        results.append(.object(["modality":.string("text"),"text":.string(chunk),"locator":.object(position)]))
                    }
                } else {
                    let image=try pdfImage(page)
                    results += try ocr(image,base:locator)
                }
                results.append(.object(["modality":.string("image"),"text":.string(""),"locator":.object(locator)]))
            }
        } else {
            let image=try opaqueImage(bytes)
            results += try ocr(image,base:[:])
            results.append(.object(["modality":.string("image"),"text":.string(""),"locator":.object([:])]))
        }
        return results
    }
    public static func preview(file: JSONValue, bytes: Data, locator: JSONValue) throws -> Data {
        var image:CGImage
        if file["mime_type"] == .string("application/pdf") {
            let number=locator["page"].intValue
            guard number>0,let document=PDFDocument(data:bytes),!document.isLocked,let page=document.page(at:number-1) else { throw MioError("invalid_source","PDF page is unavailable") }
            image=try pdfImage(page)
        } else { image=try opaqueImage(bytes) }
        for _ in 0..<3 {
            let result=NSMutableData()
            guard let destination=CGImageDestinationCreateWithData(result,UTType.png.identifier as CFString,1,nil) else { throw MioError("image_encode","Cannot encode source preview") }
            CGImageDestinationAddImage(destination,image,nil)
            guard CGImageDestinationFinalize(destination) else { throw MioError("image_encode","Cannot encode source preview") }
            if result.length<=4_000_000 { return result as Data }
            let scale=min(0.7,1100/Double(max(image.width,image.height))),width=max(1,Int(Double(image.width)*scale)),height=max(1,Int(Double(image.height)*scale))
            guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { throw MioError("image_encode","Cannot resize source preview") }
            context.interpolationQuality = .high;context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            guard let resized=context.makeImage() else { throw MioError("image_encode","Cannot resize source preview") };image=resized
        }
        throw MioError("image_encode","Source preview exceeds4MB")
    }
    private static func pdfImage(_ page: PDFPage) throws -> CGImage {
        let bounds=page.bounds(for:.mediaBox)
        guard bounds.width.isFinite,bounds.height.isFinite,bounds.width>0,bounds.height>0 else { throw MioError("image_decode","PDF page has invalid bounds") }
        let rotated=abs(page.rotation)%180==90,display=CGSize(width:rotated ? bounds.height:bounds.width,height:rotated ? bounds.width:bounds.height),scale=min(2,1600/max(display.width,display.height))
        let width=max(1,Int(display.width*scale)),height=max(1,Int(display.height*scale))
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { throw MioError("image_decode","Cannot render PDF page") }
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
        let thumbnail=page.thumbnail(of:CGSize(width:width,height:height),for:.mediaBox)
        guard let rendered=thumbnail.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw MioError("image_decode","Cannot render the oriented PDF page") }
        context.draw(rendered,in:CGRect(x:0,y:0,width:width,height:height))
        guard let image=context.makeImage() else { throw MioError("image_decode","Cannot render PDF page") };return image
    }
    private static func opaqueImage(_ data: Data) throws -> CGImage {
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1600] as CFDictionary),
              let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { throw MioError("image_decode","Cannot decode image") }
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:image.width,height:image.height));context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let opaque=context.makeImage() else { throw MioError("image_decode","Cannot prepare image") };return opaque
    }
    private static func ocr(_ image: CGImage, base: [String:JSONValue]) throws -> [JSONValue] {
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.automaticallyDetectsLanguage = true;request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
        let observations=(request.results ?? []).sorted { $0.boundingBox.maxY == $1.boundingBox.maxY ? $0.boundingBox.minX<$1.boundingBox.minX:$0.boundingBox.maxY>$1.boundingBox.maxY }
        var text="",lines:[(Int,Int,CGRect,Float)]=[]
        for observation in observations {
            guard let candidate=observation.topCandidates(1).first,!candidate.string.isEmpty else { continue }
            let start=(text as NSString).length
            text += candidate.string+"\n";lines.append((start,(candidate.string as NSString).length,observation.boundingBox,candidate.confidence))
        }
        return textChunks(text).map { chunk,start,length in
            let selected=lines.filter{$0.0<start+length && $0.0+$0.1>start},bounds=selected.reduce(CGRect.null){$0.union($1.2)}
            var locator=base
            locator["bounds"] = .array([bounds.minX,bounds.minY,bounds.width,bounds.height].map{.number(Double($0))});locator["text_method"] = .string("ocr")
            locator["utf16_start"] = .number(Double(start));locator["utf16_length"] = .number(Double(length));locator["coordinate_system"] = .string("normalized_bottom_left_on_oriented_preview")
            locator["line_boxes"] = .array(selected.map { .object(["utf16_start":.number(Double($0.0)),"utf16_length":.number(Double($0.1)),"bounds":.array([$0.2.minX,$0.2.minY,$0.2.width,$0.2.height].map{.number(Double($0))})]) })
            locator["ocr_confidence"] = .number(Double(selected.map(\.3).min() ?? 0))
            return .object(["modality":.string("text"),"text":.string(chunk),"locator":.object(locator)])
        }
    }
}
