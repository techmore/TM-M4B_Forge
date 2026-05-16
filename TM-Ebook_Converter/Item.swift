//
//  Item.swift
//  TM-Ebook_Converter
//
//  Created by techmore on 5/15/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
