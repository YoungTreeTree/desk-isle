import Foundation

struct WidgetContext {
    let draft: ScreenLayout
    let applied: ScreenLayout
    let connected: Bool
    let applying: Bool
    let revision: Int
    static let idle = WidgetContext(draft: .factory(), applied: .factory(), connected: false, applying: false, revision: 0)
}
