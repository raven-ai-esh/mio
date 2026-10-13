import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers

extension MioStore {
    func prepareCapturedFile(_ p: [String: JSONValue], noteID: String, revisionID: String, spaceID: String, maximumBytes: Int) throws -> JSONValue? {
        guard p["file_base64"] != nil || p["file_name"] != nil || p["mime_type"] != nil else { return nil }
        let name = try p.required("file_name"), mime = try p.required("mime_type")
        guard name.count <= 240, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw MioError("invalid_file_name", "Use a plain filename without a path") }
        guard let encoded = p["file_base64"]?.stringValue, encoded.utf8.count <= ((maximumBytes+2)/3)*4,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= maximumBytes else { throw MioError("invalid_file", "File bytes must be valid base64 and at most\(maximumBytes/1_000_000)MB") }
        if mime == "application/pdf" {
            guard let pdf = PDFDocument(data: bytes), pdf.pageCount > 0, pdf.pageCount <= 500 else { throw MioError("invalid_file", "PDF cannot be opened or has more than500pages") }
            guard !pdf.isLocked else { throw MioError("encrypted_file", "Unlock the PDF before adding it to Mio") }
        } else {
            guard ["image/png", "image/jpeg", "image/heic", "image/webp", "image/tiff"].contains(mime),
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil), let type = CGImageSourceGetType(source),
                  let actualMime = UTType(type as String)?.preferredMIMEType, actualMime == mime,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 40_000_000,
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) != nil else { throw MioError("invalid_file", "Supported files are PDF and decoded PNG/JPEG/HEIC/WebP/TIFF images up to40megapixels") }
        }
        let id = "file-" + UUID().uuidString.lowercased(), digest = hash(bytes)
        return .object(["id": .string(id), "kind": .string("memory_file"), "immutable": .bool(true),
                        "note_id": .string(noteID), "captured_revision_id": .string(revisionID), "space_id": .string(spaceID),
                        "file_name": .string(name), "mime_type": .string(mime), "relative_path": .string("Files/"+id+"/"+name),
                        "bytes": .string(encoded), "sha256": .string(digest), "file_version": .string(digest), "byte_count": .number(Double(bytes.count)), "timestamp": .string(now())])
    }

    func requireFile(_ id: String, _ scope: Scope) throws -> JSONValue {
        let file = try requireEntity("attachment", id, scope)
        guard file["kind"] == .string("memory_file"), !file["purged"].boolValue,
              let noteID = file["note_id"].stringValue, let revisionID = file["captured_revision_id"].stringValue else { throw MioError("source_purged", "This file source is unavailable") }
        let note = try requireEntity("note", noteID, scope), revision = try requireEntity("revision", revisionID, scope)
        guard !note["purged"].boolValue, note["status"] != .string("purged"), !revision["purged"].boolValue,
              note["space_id"] == file["space_id"], revision["space_id"] == file["space_id"], revision["note_id"] == note["id"],
              revision["file_ids"].arrayValue.contains(.string(id)), note["file_ids"].arrayValue.contains(.string(id)) else { throw MioError("forbidden", "File does not belong to this live memory source") }
        return file
    }

    func fileMetadata(_ file: JSONValue) -> JSONValue {
        var value: [String: JSONValue] = ["kind": .string("file"), "id": file["id"], "file_id": file["id"], "revision_id": file["captured_revision_id"]]
        for key in ["note_id", "space_id", "file_name", "mime_type", "sha256", "file_version", "byte_count", "timestamp"] { value[key] = file[key] }
        value["bytes_fetched"] = .bool(false)
        return .object(value)
    }
    func readFileSource(_ id: String, _ scope: Scope, params: [String:JSONValue]) throws -> JSONValue {
        let file=try requireFile(id,scope)
        guard let bytes=Data(base64Encoded:file["bytes"].stringValue ?? "") else { throw MioError("invalid_source","Original file bytes are unavailable") }
        var value=fileMetadata(file).objectValue
        let page=max(0,params["offset"]?.intValue ?? 0),count=file["mime_type"] == .string("application/pdf") ? PDFDocument(data:bytes)?.pageCount ?? 0:1
        guard page<count else { throw MioError("invalid_page","Requested page is outside this file") }
        let locator:JSONValue = .object(["page":.number(Double(page+1))])
        value["locator"] = locator;value["page_count"] = .number(Double(count));value["title"] = file["file_name"]
        if let renderer=sourceImageRenderer { value["media"] = .object(["mime_type":.string("image/png"),"data":.string(try renderer(file,bytes,locator).base64EncodedString())]) }
        return .object(value)
    }
}
