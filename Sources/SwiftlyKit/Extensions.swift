extension Substring {

    var isASCIIDecimal: Bool {
        !isEmpty && utf8.allSatisfy { (48...57).contains($0) }
    }

}

extension String {

    var isASCIIHexadecimal: Bool {
        !isEmpty && utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

}
