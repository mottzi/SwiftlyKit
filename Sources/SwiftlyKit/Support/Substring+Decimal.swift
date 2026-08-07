extension Substring {
    
    var isASCIIDecimal: Bool {
        !isEmpty && utf8.allSatisfy { (48...57).contains($0) }
    }
    
}
