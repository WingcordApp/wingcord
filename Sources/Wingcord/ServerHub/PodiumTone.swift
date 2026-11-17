import SwiftUI

/// Gold, silver, bronze.
struct PodiumTone {
    var rim: Color
    var glow: Color
    var fill: [Color]
    var medal: [Color]

    init(place: Int) {
        switch place {
        case 1:
            rim = Color(hex: 0xF2C14E)
            glow = Color(hex: 0xF5B638)
            fill = [Color(hex: 0x6B4A2C), Color(hex: 0x3A2818)]
            medal = [Color(hex: 0xFFD966), Color(hex: 0xE8A317)]
        case 2:
            rim = Color(hex: 0xC9D3E3)
            glow = Color(hex: 0xB8C4D6)
            fill = [Color(hex: 0x353B4C), Color(hex: 0x1F2330)]
            medal = [Color(hex: 0xE3E8EF), Color(hex: 0x9AA5B4)]
        default:
            rim = Color(hex: 0xE08A4F)
            glow = Color(hex: 0xD9773A)
            fill = [Color(hex: 0x4A2E24), Color(hex: 0x2A1A15)]
            medal = [Color(hex: 0xF4B07A), Color(hex: 0xB86B2E)]
        }
    }
}
