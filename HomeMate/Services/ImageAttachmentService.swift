import UIKit

/// Device image processing shared by the profile and private-notes ViewModels.
@MainActor
enum ImageAttachmentService {
    static func profileThumbnail(_ data: Data) throws -> Data {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { throw invalidImage }
        let side: CGFloat = 512
        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            let scale = max(side / image.size.width, side / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (side-size.width)/2, y: (side-size.height)/2, width: size.width, height: size.height))
        }
        guard let result = thumbnail.jpegData(compressionQuality: 0.8) else { throw invalidImage }
        return result
    }
    static func noteThumbnail(_ data: Data) throws -> Data {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { throw invalidImage }
        let ratio = min(1, 1000 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let thumbnail = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let result = thumbnail.jpegData(compressionQuality: 0.7) else { throw invalidImage }
        return result
    }
    private static var invalidImage: NSError { NSError(domain: "HomeMate.Image", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open that photo."]) }
}
