import SwiftUI
import UIKit

/// The look from the prototype: near-black, one soft blue, rounded type.
enum Theme {
    static let accent = Color(red: 0.49, green: 0.77, blue: 1.0)
    static let bg = Color(red: 0.027, green: 0.035, blue: 0.047)
    static let hero = Color(red: 0.06, green: 0.10, blue: 0.15)
    static let heroLabel = Color(red: 0.56, green: 0.73, blue: 0.87)
    static let track = Color(red: 0.11, green: 0.17, blue: 0.23)
    static let warn = Color(red: 0.95, green: 0.71, blue: 0.36)
    /// Walking, beside workouts but not one of them.
    static let walk = Color(red: 0.36, green: 0.82, blue: 0.56)
    /// Each meal's colour in the calorie bar.
    static func meal(_ meal: String) -> Color {
        switch meal {
        case "Breakfast": return Color(red: 0.98, green: 0.78, blue: 0.40)
        case "Lunch": return Color(red: 0.36, green: 0.82, blue: 0.62)
        case "Dinner": return accent
        default: return Color(red: 0.93, green: 0.55, blue: 0.70)
        }
    }
    static let uiBackground = UIColor(red: 0.027, green: 0.035, blue: 0.047, alpha: 1)

    static func tone(_ name: String) -> (bg: Color, fg: Color) {
        switch toneKey(name) {
        case 0: return (Color(red: 0.16, green: 0.13, blue: 0.09), Color(red: 0.95, green: 0.78, blue: 0.47))
        case 1: return (Color(red: 0.08, green: 0.14, blue: 0.19), accent)
        case 2: return (Color(red: 0.14, green: 0.10, blue: 0.17), Color(red: 0.84, green: 0.64, blue: 0.94))
        default: return (Color(red: 0.11, green: 0.16, blue: 0.12), Color(red: 0.56, green: 0.86, blue: 0.67))
        }
    }
    private static func toneKey(_ name: String) -> Int { abs(name.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 4 }

    /// An SF Symbol that fits the food, roughly.
    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        let table: [(String, [String])] = [
            ("cup.and.saucer.fill", ["coffee", "flat white", "latte", "tea", "cappuccino"]),
            ("wineglass.fill", ["wine", "prosecco", "champagne"]),
            ("mug.fill", ["beer", "cider", "lager", "ale"]),
            ("birthday.cake.fill", ["cake", "brownie", "muffin", "cookie", "biscuit", "tim tam", "chocolate"]),
            ("carrot.fill", ["salad", "veg", "carrot", "broccoli", "spinach"]),
            ("fish.fill", ["salmon", "tuna", "fish", "prawn", "shrimp"]),
            ("frying.pan.fill", ["egg", "omelette", "bacon", "scrambled"]),
            ("leaf.fill", ["apple", "banana", "orange", "berries", "fruit", "grape"]),
            ("takeoutbag.and.cup.and.straw.fill", ["burger", "fries", "chips", "kebab", "takeaway", "pizza"]),
            ("fork.knife", ["pasta", "curry", "rice", "noodle", "chicken", "beef", "steak", "pad thai", "bowl", "wrap", "sandwich"])
        ]
        for (symbol, words) in table where words.contains(where: { n.contains($0) }) { return symbol }
        return "fork.knife"
    }
}

/// A round icon for a food line: a full-colour emoji of the food on a soft tint (a plain symbol if nothing fits).
struct FoodDot: View {
    let name: String
    var size: CGFloat = 34
    var body: some View {
        let t = Theme.tone(name)
        Group {
            if let e = FoodEmoji.for(name) {
                // Microsoft's Fluent flat icon for it when we have one, else the phone's own emoji; no circle behind
                if let img = UIImage(named: FoodEmoji.asset(e)) { Image(uiImage: img).resizable().scaledToFit().padding(size * 0.06) }
                else { Text(e).font(.system(size: size * 0.78)) }
            } else {
                // nothing matched: a plate, so every food still has a picture
                if let img = UIImage(named: FoodEmoji.asset("🍽️")) { Image(uiImage: img).resizable().scaledToFit().padding(size * 0.06) }
                else {
                    Image(systemName: Theme.symbol(for: name)).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(t.fg)
                        .frame(width: size, height: size).background(t.bg, in: Circle())
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One of the bundled Fluent icons by its emoji (the phone's own emoji if it isn't bundled).
struct FluentIcon: View {
    let emoji: String
    var size: CGFloat = 28
    var body: some View {
        if let img = UIImage(named: FoodEmoji.asset(emoji)) {
            Image(uiImage: img).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            Text(emoji).font(.system(size: size * 0.85)).frame(width: size, height: size)
        }
    }
}

/// Which emoji fits a food's name. More specific words come first ("chicken burger" is a burger, "egg fried rice" is rice).
enum FoodEmoji {
    private static let table: [(String, [String])] = [
        // drinks
        ("🧋", ["bubble tea", "boba"]), ("🥤", ["coke", "cola", "pepsi", "soft drink", "fanta", "sprite", "lemonade", "energy drink", "red bull", "monster", "smoothie", "milkshake", "shake"]),
        ("☕️", ["coffee", "flat white", "latte", "cappuccino", "espresso", "americano", "mocha", "macchiato", "long black"]), ("🍵", ["matcha", "green tea", "tea", "chai"]),
        ("🍺", ["beer", "lager", "ale", "cider", "stout", "pint"]), ("🍷", ["wine", "prosecco", "champagne", "rosé"]), ("🍸", ["cocktail", "martini", "margarita", "spritz", "gin", "vodka"]),
        ("🥃", ["whisky", "whiskey", "rum", "bourbon"]), ("🥛", ["milk"]), ("🧃", ["juice"]), ("💧", ["water"]),
        // fast food and dishes
        ("🍕", ["pizza"]), ("🍔", ["burger", "cheeseburger", "big mac", "whopper"]), ("🌭", ["hot dog", "hotdog", "sausage roll"]), ("🍟", ["fries", "chips", "wedges", "hash brown"]),
        ("🌮", ["taco"]), ("🌯", ["burrito", "wrap", "kebab", "gyro", "souvlaki", "shawarma"]), ("🥙", ["pita", "falafel"]), ("🥪", ["sandwich", "sub", "toastie", "panini", "baguette", "roll"]),
        ("🍣", ["sushi", "sashimi", "nigiri"]), ("🍱", ["bento"]), ("🥟", ["dumpling", "gyoza", "dim sum", "bao", "wonton"]), ("🍜", ["ramen", "pho", "noodle", "laksa", "udon", "pad thai", "chow mein", "soba"]),
        ("🍝", ["pasta", "spaghetti", "lasagne", "lasagna", "bolognese", "carbonara", "penne", "mac and cheese", "macaroni", "gnocchi", "ravioli"]),
        ("🍛", ["curry", "korma", "tikka", "butter chicken", "biryani", "dal", "dahl"]), ("🍚", ["rice", "risotto", "fried rice"]), ("🌶️", ["chilli sauce", "chili sauce", "hot sauce", "sweet chilli", "sriracha", "tabasco", "jalapeno", "peri peri"]), ("🥘", ["paella", "stew", "casserole", "chilli", "chili"]),
        ("🍲", ["soup", "hot pot", "broth"]), ("🥗", ["salad", "poke", "buddha bowl", "slaw"]), ("🥧", ["pie", "quiche", "pasty"]), ("🫔", ["tamale", "enchilada"]),
        // meat, fish, eggs
        ("🍗", ["chicken", "wings", "drumstick", "nugget", "schnitzel", "turkey"]), ("🥩", ["steak", "beef", "lamb", "mince", "pork", "veal"]), ("🥓", ["bacon", "ham", "prosciutto", "salami"]),
        ("🍤", ["prawn", "shrimp", "tempura"]), ("🐟", ["salmon", "tuna", "fish", "cod", "barramundi", "sardine", "mackerel"]), ("🦐", ["seafood"]), ("🍳", ["omelette", "fried egg", "scrambled", "frittata"]), ("🥚", ["egg"]),
        // bakery and breakfast
        ("🥞", ["pancake", "crepe", "pikelet"]), ("🧇", ["waffle"]), ("🥐", ["croissant", "pastry", "danish", "pain au"]), ("🥯", ["bagel"]), ("🍞", ["toast", "bread", "sourdough", "crumpet", "muffin english"]),
        ("🥣", ["cereal", "porridge", "oats", "oatmeal", "granola", "muesli", "weet-bix", "weetbix", "cornflakes"]),
        // sweets and snacks
        ("🍩", ["donut", "doughnut"]), ("🧁", ["cupcake", "muffin"]), ("🍰", ["cake", "cheesecake", "slice", "tart"]), ("🍪", ["cookie", "biscuit", "tim tam", "oreo"]), ("🍫", ["chocolate", "brownie", "kitkat", "kit kat", "snickers", "mars", "twix", "freddo", "dairy milk"]),
        ("🍦", ["ice cream", "gelato", "sundae", "frozen yoghurt", "froyo"]), ("🍬", ["lolly", "lollies", "sweets", "candy", "gummy", "jelly"]), ("🍿", ["popcorn"]), ("🥨", ["pretzel"]),
        ("🥜", ["peanut", "nuts", "almond", "cashew", "walnut", "trail mix", "peanut butter"]), ("🍯", ["honey"]), ("🧀", ["cheese", "brie", "cheddar", "feta", "halloumi"]),
        ("🥫", ["baked beans", "beans"]), ("🍫", ["protein bar", "muesli bar", "bar"]), ("🥣", ["yoghurt", "yogurt", "skyr"]), ("🧈", ["butter", "margarine"]), ("🫒", ["olive", "oil"]),
        ("🫙", ["mayo", "mayonnaise", "aioli", "kewpie", "ketchup", "sauce", "dressing", "mustard", "relish", "pesto", "hummus", "houmous", "dip", "spread", "jam", "vegemite", "marmite", "nutella", "syrup"]),
        // fruit and veg
        ("🍌", ["banana"]), ("🍎", ["apple"]), ("🍊", ["orange", "mandarin"]), ("🍓", ["strawberr"]), ("🫐", ["blueberr", "berries", "berry"]), ("🍇", ["grape"]), ("🍉", ["watermelon"]), ("🍍", ["pineapple"]),
        ("🥭", ["mango"]), ("🍑", ["peach", "nectarine"]), ("🍐", ["pear"]), ("🥝", ["kiwi"]), ("🍒", ["cherr"]), ("🥑", ["avocado", "avo", "guacamole"]), ("🍅", ["tomato"]),
        ("🥦", ["broccoli", "veg", "vegetable", "greens", "spinach", "kale", "zucchini", "beans green"]), ("🥕", ["carrot"]), ("🌽", ["corn"]), ("🥔", ["potato", "mash"]), ("🍠", ["sweet potato"]),
        ("🍄", ["mushroom"]), ("🥒", ["cucumber"]), ("🫑", ["capsicum", "pepper"]), ("🧅", ["onion"]), ("🍋", ["lemon", "lime"]), ("🥥", ["coconut"]),
        // general
        ("🍽️", ["dinner", "lunch", "meal", "plate", "roast", "bowl"])
    ]

    /// The bundled icon's name for an emoji (Fluent Emoji, flat style, MIT licence; added by tools/fluent.py).
    static func asset(_ emoji: String) -> String {
        "food-" + emoji.unicodeScalars.filter { $0.value != 0xFE0F }.map { String($0.value, radix: 16) }.joined(separator: "-")
    }

    /// Phrases first ("dairy milk", "butter chicken", "sweet potato"), then single words in the table's order.
    /// Whole words only, so steak isn't tea and rump isn't rum; longer words also match their plurals.
    static func `for`(_ name: String) -> String? {
        let n = name.lowercased()
        func hit(_ w: String) -> Bool {
            let esc = NSRegularExpression.escapedPattern(for: w.trimmingCharacters(in: .whitespaces))
            let pattern = w.count <= 4 ? "\\b\(esc)(s|es)?\\b" : "\\b\(esc)"
            return n.range(of: pattern, options: .regularExpression) != nil
        }
        for (e, words) in table where words.contains(where: { $0.contains(" ") && hit($0) }) { return e }
        for (e, words) in table where words.contains(where: { !$0.contains(" ") && hit($0) }) { return e }
        return nil
    }
}

/// Small uppercase labels above big numbers.
struct Eyebrow: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(color)
    }
}

/// A pizza slice drawn to match the app's icons (SF Symbols has no pizza): crust, a line under it, and pepperoni cut out.
struct PizzaSlice: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        let top = r.minY + h * 0.24, left = r.minX + w * 0.06, right = r.maxX - w * 0.06, tip = CGPoint(x: r.midX, y: r.maxY)
        p.move(to: tip)
        p.addLine(to: CGPoint(x: left, y: top))
        p.addQuadCurve(to: CGPoint(x: right, y: top), control: CGPoint(x: r.midX, y: r.minY - h * 0.06))
        p.closeSubpath()
        // the line between crust and topping, cut out (even-odd fill)
        func side(_ y: CGFloat) -> CGFloat { (r.midX - left) * (r.maxY - y) / (r.maxY - top) }
        let y1 = top + h * 0.09, y2 = top + h * 0.15
        p.move(to: CGPoint(x: r.midX - side(y1) + w * 0.05, y: y1))
        p.addQuadCurve(to: CGPoint(x: r.midX + side(y1) - w * 0.05, y: y1), control: CGPoint(x: r.midX, y: y1 - h * 0.27))
        p.addLine(to: CGPoint(x: r.midX + side(y2) - w * 0.06, y: y2))
        p.addQuadCurve(to: CGPoint(x: r.midX - side(y2) + w * 0.06, y: y2), control: CGPoint(x: r.midX, y: y2 - h * 0.27))
        p.closeSubpath()
        for (x, y, d) in [(0.37, 0.50, 0.15), (0.60, 0.53, 0.13), (0.49, 0.71, 0.12)] as [(CGFloat, CGFloat, CGFloat)] {
            p.addEllipse(in: CGRect(x: r.minX + w * x - w * d / 2, y: r.minY + h * y - w * d / 2, width: w * d, height: w * d))
        }
        return p
    }
}

/// The app's logo mark, traced from the icon: a stadium ring cut by two slashes into a C and a D.
/// Measured on the 1199 px source (the mark spans 257...920 by 474...826), so it draws true at any size.
struct LogoMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w0: CGFloat = 663, h0: CGFloat = 352, t: CGFloat = 89
        let s = min(rect.width / w0, rect.height / h0)
        let ox = rect.midX - w0 * s / 2, oy = rect.midY - h0 * s / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + (x - 257) * s, y: oy + (y - 474) * s) }
        let outer = Path(roundedRect: CGRect(origin: p(257, 474), size: CGSize(width: w0 * s, height: h0 * s)), cornerRadius: h0 * s / 2)
        let inner = Path(roundedRect: CGRect(origin: p(257 + t, 474 + t), size: CGSize(width: (w0 - 2 * t) * s, height: (h0 - 2 * t) * s)),
                         cornerRadius: (h0 - 2 * t) * s / 2)
        // the slashes: parallel, 52 wide, the top one further right
        func slash(_ x: CGFloat, _ y: CGFloat, _ y1: CGFloat, _ y2: CGFloat) -> Path {
            let lx = { (yy: CGFloat) in x - 0.6 * (yy - y) }
            var g = Path()
            g.move(to: p(lx(y1), y1)); g.addLine(to: p(lx(y1) + 52, y1)); g.addLine(to: p(lx(y2) + 52, y2)); g.addLine(to: p(lx(y2), y2))
            g.closeSubpath()
            return g
        }
        return outer.subtracting(inner).subtracting(slash(597.5, 518, 440, 600)).subtracting(slash(527, 780, 700, 860))
    }
}

struct PizzaIcon: View {
    var size: CGFloat = 22
    var color: Color = Theme.warn
    var body: some View {
        PizzaSlice().fill(color, style: FillStyle(eoFill: true)).frame(width: size, height: size)
    }
}

/// Lifts the bottom of a screen clear of the keyboard by watching the keyboard itself, instead of SwiftUI's keyboard
/// safe area, which inside a sheet sometimes never updates (the chat box stayed under the keyboard) or never resets.
struct KeyboardLift: ViewModifier {
    @State private var keyboardTop: CGFloat?   // in screen points; nil when it's away

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let lift = keyboardTop.map { max(0, geo.frame(in: .global).maxY - $0) } ?? 0
            content.frame(width: geo.size.width, height: max(0, geo.size.height - lift), alignment: .top)
        }
        .ignoresSafeArea(.keyboard)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screen = UIScreen.main.bounds.height
            withAnimation(.snappy(duration: 0.25)) { keyboardTop = f.minY >= screen - 1 || f.height < 1 ? nil : f.minY }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.snappy(duration: 0.25)) { keyboardTop = nil }
        }
    }
}

/// For a list of boxes with a bar pinned over its foot. Locking the phone with the keyboard up could leave the
/// keyboard's safe area behind, squashing the whole list and stranding the bar mid-screen; so the list ignores the
/// keyboard and makes its own room: a bottom margin the keyboard's height, and the box being typed in scrolled clear.
struct KeyboardRoom: ViewModifier {
    var base: CGFloat
    @State private var height: CGFloat = 0
    @State private var field = Field()
    final class Field { weak var view: UITextField? }

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content
                .contentMargins(.bottom, base + max(0, height - geo.safeAreaInsets.bottom), for: .scrollContent)
        }
        .ignoresSafeArea(.keyboard)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            height = max(0, UIScreen.main.bounds.height - f.minY)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in height = 0 }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in reveal() }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { n in
            field.view = n.object as? UITextField
            if height > 0 { reveal() }
        }
        // put the keyboard away when the phone locks or the app goes behind, so nothing is left half-shown on return
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            height = 0
        }
    }

    /// Scrolls the box being typed in up until it clears the keyboard's top by a little, worked out from where the
    /// keyboard really is (scrollRectToVisible went by the list's own insets, and left the box half under it).
    private func reveal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let tf = field.view, tf.isFirstResponder, height > 0, let window = tf.window else { return }
            var v = tf.superview
            while let s = v, !(s is UIScrollView) { v = s.superview }
            guard let scroll = v as? UIScrollView else { return }
            let keyboardTop = window.bounds.height - height
            let over = tf.convert(tf.bounds, to: window).maxY + 16 - keyboardTop
            guard over > 0 else { return }
            let most = max(0, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(most, scroll.contentOffset.y + over)), animated: true)
        }
    }
}

extension View {
    func keyboardLift() -> some View { modifier(KeyboardLift()) }
    func keyboardRoom(_ base: CGFloat) -> some View { modifier(KeyboardRoom(base: base)) }

    /// Tapping into a box puts the cursor after the number, wherever the tap landed (the numbers sit on the right of
    /// a wide box, so a tap usually lands on the empty left and the cursor ended up in front of the digits).
    func cursorAtEnd() -> some View {
        onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { n in
            guard let tf = n.object as? UITextField else { return }
            // after the tap has placed its own cursor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                tf.selectedTextRange = tf.textRange(from: tf.endOfDocument, to: tf.endOfDocument)
            }
        }
    }

    /// Marks a screen that types: the Done bar itself comes from KeyboardDone, on every field in the app. (SwiftUI's
    /// keyboard toolbar went missing in sheets and on screens with more than one, so it's no longer used.)
    func keyboardDone() -> some View { self }
}

extension UIResponder {
    /// Whichever field has the keyboard, found by asking the first responder to name itself.
    @MainActor static weak var current: UIResponder?
    @objc func cdFindCurrent() { UIResponder.current = self }
}

/// A Done bar above every keyboard in the app: number keyboards have no return key, and this puts any keyboard away
/// (keeping what was typed). Fitted to each text field as it starts editing, so no screen can miss it.
@MainActor
enum KeyboardDone {
    static func install() {
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                let field = n.object
                MainActor.assumeIsolated { attach(field) }
            }
        }
        // and again as the keyboard comes up, in case SwiftUI put its own accessory back in between
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                UIResponder.current = nil
                UIApplication.shared.sendAction(#selector(UIResponder.cdFindCurrent), to: nil, from: nil, for: nil)
                attach(UIResponder.current)
            }
        }
    }

    private static let tag = 0xD0E   // marks our bar, so it's put on once
    /// SwiftUI gives its text fields an (empty) accessory view of its own, so ours replaces whatever's there: nothing
    /// in the app uses SwiftUI's keyboard toolbar any more.
    private static func attach(_ field: Any?) {
        if let f = field as? UITextField, f.inputAccessoryView?.tag != tag { f.inputAccessoryView = bar(for: f); f.reloadInputViews() }
        else if let v = field as? UITextView, v.isEditable, v.inputAccessoryView?.tag != tag { v.inputAccessoryView = bar(for: v); v.reloadInputViews() }
    }

    private static func bar(for field: UIView) -> UIToolbar {
        let t = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        t.tag = tag
        // told which field it belongs to: the bar sits in the keyboard's window, outside the field's responder chain,
        // so an action sent up the chain from it never reached the field
        let done = UIBarButtonItem(title: "Done", style: .done, primaryAction: UIAction { [weak field] _ in
            if let field, field.isFirstResponder { field.resignFirstResponder() }
            else { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            // SwiftUI focus can hold on: the window gives it up too
            field?.window?.endEditing(true)
        })
        done.tintColor = UIColor(Theme.accent)
        t.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        t.sizeToFit()
        return t
    }
}
