import CoreImage.CIFilterBuiltins
import SwiftUI

struct QRCodeView: View {
    let text: String
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .padding(10)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var image: UIImage {
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent) else {
            return UIImage()
        }
        return UIImage(cgImage: cgImage)
    }
}

