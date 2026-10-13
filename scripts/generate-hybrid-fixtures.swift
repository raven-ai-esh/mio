import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

let out=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
guard !FileManager.default.fileExists(atPath:out.path) else { fatalError("Use a new source-only directory") }
try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
func digest(_ d:Data)->String { SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined() }
func text(_ t:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ c:CGContext) {
    c.textPosition=CGPoint(x:x,y:y)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string:t,attributes:[.init(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,size,nil),.init(kCTForegroundColorAttributeName as String):CGColor(gray:0.05,alpha:1)])),c)
}
func png(_ kind:String)->Data {
    let c=CGContext(data:nil,width:960,height:640,bitsPerComponent:8,bytesPerRow:3840,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:960,height:640))
    if kind=="notice" { text("Quiet hours",80,480,54,c);text("22:00 - 07:00",80,365,64,c);text("Please keep the corridor silent.",80,250,32,c) }
    else if kind=="car" {
        c.setFillColor(CGColor(red:0.86,green:0.05,blue:0.04,alpha:1));c.fill(CGRect(x:160,y:190,width:640,height:140))
        c.move(to:CGPoint(x:260,y:330));c.addLine(to:CGPoint(x:375,y:465));c.addLine(to:CGPoint(x:575,y:465));c.addLine(to:CGPoint(x:700,y:330));c.closePath();c.fillPath()
        c.setFillColor(CGColor(red:0.65,green:0.88,blue:1,alpha:1));c.fill(CGRect(x:387,y:352,width:78,height:90));c.fill(CGRect(x:485,y:352,width:78,height:90))
        c.setFillColor(CGColor(gray:0.08,alpha:1));for x in [310,650] { c.fillEllipse(in:CGRect(x:x-72,y:130,width:144,height:144)) }
        c.setFillColor(CGColor(gray:0.62,alpha:1));for x in [310,650] { c.fillEllipse(in:CGRect(x:x-30,y:172,width:60,height:60)) }
    } else {
        c.setFillColor(CGColor(red:0.65,green:0.88,blue:1,alpha:1));c.fill(CGRect(x:0,y:0,width:960,height:160))
        c.setStrokeColor(CGColor(gray:0.2,alpha:1));c.setLineWidth(14);c.move(to:CGPoint(x:470,y:210));c.addLine(to:CGPoint(x:470,y:530));c.strokePath()
        for (r,g,b,points) in [(0.05,0.35,0.88,[(450.0,525.0),(450,260),(190,260)]),(0.18,0.6,1.0,[(492.0,460.0),(710,260),(492,260)]),(0.4,0.19,0.07,[(170.0,210.0),(780,210),(650,115),(270,115)])] {
            c.setFillColor(CGColor(red:r,green:g,blue:b,alpha:1));c.move(to:CGPoint(x:points[0].0,y:points[0].1));for p in points.dropFirst(){c.addLine(to:CGPoint(x:p.0,y:p.1))};c.closePath();c.fillPath()
        }
    }
    let bytes=NSMutableData(),d=CGImageDestinationCreateWithData(bytes,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(d,c.makeImage()!,nil);assert(CGImageDestinationFinalize(d));return bytes as Data
}
func pdf(_ scan:Data?=nil)->Data {
    let bytes=NSMutableData(),consumer=CGDataConsumer(data:bytes as CFMutableData)!
    var box=CGRect(x:0,y:0,width:720,height:540);let c=CGContext(consumer:consumer,mediaBox:&box,nil)!
    let pages=scan != nil ? [[]] : [
        ["Willow House arrival policy","Rooms become available at 16:00.","Guests must bring the booking reference and a passport.","Reception stores baggage without charge before check-in."],
        ["Willow House cancellation policy","A booking may be cancelled without a fee until seven days before arrival.","Later cancellation costs one night. No-shows cost two nights.","Refunds return to the original payment card within ten business days."],
        ["Willow House animal policy","Only assistance dogs are admitted to the guest rooms.","There is no pet surcharge for an assistance dog.","Ordinary pets cannot stay at the property."]]
    for lines in pages { c.beginPDFPage(nil);if let scan { c.draw(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(scan as CFData,nil)!,0,nil)!,in:box) } else { for (i,line) in lines.enumerated(){text(line,35,470-CGFloat(i)*55,i==0 ? 24:16,c)} };c.endPDFPage() };c.closePDF();return bytes as Data
}
let notes:[[String:String]]=[
    ["key":"integrity","title":"Release validation","body":"Record a SHA-256 digest before sending a release archive. Compute the digest again on the receiving machine and compare the two values. Equal values establish byte integrity; they do not establish that the application behaves correctly."],
    ["key":"database","title":"Storage decision","body":"SQLite transactions keep revisions, audit and delivery queue consistent during a local commit. Write-ahead logging recovers committed changes after process termination. A backup must account for the WAL file or use the database backup API."],
    ["key":"garden","title":"Greenhouse log","body":"Tomato seedlings wilted when the irrigation pump stopped. Replacing the timer restored watering. The next inspection should verify that the soil is damp below the surface."],
    ["key":"kitchen","title":"Kitchen record","body":"The stew scorched because the burner was too hot. Use a heavy-bottomed pan, reduce the flame and stir occasionally. A lid slows evaporation; it does not prevent food sticking to the bottom."],
    ["key":"orbit","title":"Astronomy record","body":"The satellite follows an elliptical orbit with Earth at one focus. The point closest to Earth is perigee. The most distant point is apogee."],
    ["key":"battery","title":"Field equipment","body":"The sensor shuts down when the cell voltage falls below 3.2 volts. Its low-voltage indicator blinks amber. The field kit contains a replacement cell and a spare fuse."]]
var files:[[String:Any]]=[]
for (key,name,mime,data) in [("policies","record-01.pdf","application/pdf",pdf()),("notice","record-02.png","image/png",png("notice")),("visual-one","record-03.png","image/png",png("car")),("visual-two","record-04.png","image/png",png("boat")),("scan","record-05.pdf","application/pdf",pdf(png("notice")))] {
    try data.write(to:out.appendingPathComponent(name));files.append(["key":key,"path":name,"mime_type":mime,"sha256":digest(data),"byte_count":data.count,"title":"Source record \(files.count+1)"])
}
let corpus:[String:Any]=["language":"English","boundary":"Fictional source-only fixture; no queries or gold labels.","notes":notes,"files":files]
let bytes=try JSONSerialization.data(withJSONObject:corpus,options:[.sortedKeys,.withoutEscapingSlashes,.prettyPrinted])
try bytes.write(to:out.appendingPathComponent("corpus.json"))
try JSONSerialization.data(withJSONObject:["corpus_sha256":digest(bytes),"files":files],options:[.sortedKeys,.prettyPrinted]).write(to:out.appendingPathComponent("freeze-manifest.json"))
print("Frozen source-only fixture: \(out.path)")
