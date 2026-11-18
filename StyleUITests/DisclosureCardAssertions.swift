import XCTest
import UIKit

// Shared by the shipping SettingsView and RepositoryCommunitySection fixture tests.
extension XCTestCase {
    func tapNativeDisclosureHeader(_ header: XCUIElement, trailing: Bool) {
        XCTAssertTrue(header.isHittable)
        XCTAssertGreaterThanOrEqual(header.frame.height + 24, 44, "The reference header includes 12pt vertical padding on each side")
        XCTAssertGreaterThan(header.frame.width, 200, "The label must fill the native header, not just its text")
        header.coordinate(withNormalizedOffset: CGVector(dx: trailing ? 0.9 : 0.1, dy: 0.5)).tap()
    }

    func disclosureCard(_ app: XCUIApplication, headerID: String) -> XCUIElement {
        let id = headerID == "repository-more" ? "repository-community-card" :
            (headerID == "home-issues-disclosure" ? "home-issues-card" : headerID + "-card")
        return app.otherElements.matching(identifier: id).firstMatch
    }

    func assertDisclosureCard(_ app: XCUIApplication, headerID: String, childIDs: [String], phase: String = "disclosure") {
        let card = disclosureCard(app, headerID: headerID)
        XCTAssertTrue(card.exists)
        let started = ProcessInfo.processInfo.systemUptime
        var trace = ["context=\(phase); header=\(headerID); children=\(childIDs)"]
        func record(_ step: String, frame: CGRect, samples: Int, queryStarted: TimeInterval) {
            let now = ProcessInfo.processInfo.systemUptime
            let row = "phase=\(phase)/\(step); frame=\(frame); stableCount=\(samples); elapsed=\(now - started); queryDuration=\(now - queryStarted)"
            trace.append(row)
            print("Disclosure settle: " + row)
        }
        defer {
            let report = XCTAttachment(string: trace.joined(separator: "\n"))
            report.name = "disclosure-stability-timing-and-ax"
            report.lifetime = .keepAlways; add(report)
        }
        var seed: CGRect?
        // Expanding a card near the bottom can put its corners outside the viewport.
        for _ in 0..<6 {
            let queryStarted = ProcessInfo.processInfo.systemUptime
            let frame = card.frame
            record("reveal", frame: frame, samples: frame.isEmpty ? 0 : 1, queryStarted: queryStarted)
            let bar = app.navigationBars.firstMatch
            let visibleTop = bar.exists ? bar.frame.maxY : app.frame.minY
            let tab = app.tabBars.firstMatch
            let visibleBottom = tab.exists ? tab.frame.minY : app.frame.maxY
            if !frame.isEmpty && frame.minY >= visibleTop + 2 && frame.maxY <= visibleBottom - 2 {
                seed = frame
                break
            }
            let scroll = app.scrollViews.firstMatch
            guard scroll.exists else { break }
            if frame.maxY > visibleBottom { scroll.swipeUp() }
            else { scroll.swipeDown() }
            seed = nil // A scroll invalidates all pre-gesture geometry.
        }
        // The final visible reveal frame is observation one, not discarded AX work.
        var previous = seed ?? .zero
        var samples = previous.isEmpty ? 0 : 1
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while samples < 3 && ProcessInfo.processInfo.systemUptime < deadline {
            let queryStarted = ProcessInfo.processInfo.systemUptime
            let frame = card.frame
            samples = frame.isEmpty ? 0 : (frame == previous ? samples + 1 : 1)
            previous = frame
            record("stabilize", frame: frame, samples: samples, queryStarted: queryStarted)
            if samples < 3 {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            }
        }
        guard samples >= 3, ProcessInfo.processInfo.systemUptime <= deadline else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "disclosure-settle-timeout-" + headerID + "-" + phase
            screenshot.lifetime = .keepAlways; add(screenshot)
            trace.append("timeout AX:\n" + app.debugDescription)
            return XCTFail("Three consecutive nonempty equal frames required within 10s: \(headerID), \(phase)\n" + trace.joined(separator: "\n"))
        }
        let header = app.descendants(matching: .any).matching(identifier: headerID).firstMatch
        let headerFrame = header.frame, cardFrame = previous, appWidth = app.frame.width
        XCTAssertTrue(cardFrame.contains(headerFrame))
        if childIDs.isEmpty && headerID != "repository-more" {
            XCTAssertGreaterThanOrEqual(cardFrame.height, 44)
            XCTAssertEqual(cardFrame.height, max(headerFrame.height, 20) + 24, accuracy: 2,
                           "A collapsed card must not add another 44pt minimum before its 12pt padding")
        }
        var last = headerFrame
        for id in childIDs {
            let child = app.buttons[id]
            XCTAssertTrue(child.exists)
            XCTAssertTrue(child.isHittable, "Each native child remains independently actionable: \(id)")
            XCTAssertTrue(cardFrame.contains(child.frame), "Disclosure children must stay in the same clipped card")
            XCTAssertTrue(card.descendants(matching: .button).matching(identifier: id).firstMatch.exists)
            // AX NavigationLink bounds may be the text, not the 44pt layout row.
            // Validate ordering here; the painted interval is checked below for every child.
            XCTAssertGreaterThanOrEqual(child.frame.minY, last.maxY - 1)
            last = child.frame
        }
        let screenshot = app.screenshot()
        guard let image = screenshot.image.cgImage else { return XCTFail("Missing screenshot") }
        let scale = CGFloat(image.width) / appWidth
        let navigationBar = app.navigationBars.firstMatch
        let visibleTop = navigationBar.exists ? navigationBar.frame.maxY : app.frame.minY
        func attachCardFailure(_ detail: String) {
            let png = XCTAttachment(data: screenshot.pngRepresentation, uniformTypeIdentifier: "public.png")
            png.name = "disclosure-card-failure-" + headerID
            png.lifetime = .keepAlways; add(png)
            let frames = XCTAttachment(string: "card=\(cardFrame); header=\(headerFrame); app=\(app.frame); visibleTop=\(visibleTop); scale=\(scale); \(detail)")
            frames.name = "disclosure-card-failure-frame-" + headerID
            frames.lifetime = .keepAlways; add(frames)
        }
        guard cardFrame.minY >= visibleTop, cardFrame.maxY <= app.frame.maxY else {
            attachCardFailure("Card corners must be visible, not covered by navigation or outside the screen")
            return XCTFail("Card corners are not visible: \(headerID)")
        }
        func pixel(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            guard let crop = image.cropping(to: CGRect(x: x * scale, y: y * scale, width: 1, height: 1)) else { return [] }
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return bytes.prefix(3).map(Int.init)
        }
        func distance(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).map { abs($0 - $1) }.max() ?? 255 }
        let background = pixel(2, headerFrame.midY)
        guard let left = (0..<80).first(where: { distance(pixel(CGFloat($0), headerFrame.midY), background) > 8 }),
              let right = (0..<80).first(where: { distance(pixel(appWidth - 1 - CGFloat($0), headerFrame.midY), background) > 8 })
        else { return XCTFail("No visible card edges: \(headerID)") }
        let leftX = CGFloat(left), rightX = appWidth - CGFloat(right) - 1
        let fill = pixel(leftX + 4, headerFrame.midY)
        let frame = cardFrame
        // Inspect the actual whole card, not a fabricated List cell boundary.
        for y in [frame.minY + 1, frame.maxY - 2] {
            for x in [leftX + 1, rightX - 1] {
                let color = pixel(x, y), delta = distance(color, background)
                if delta > 8 {
                    attachCardFailure("corner=(\(x),\(y)); pixel=\(color); background=\(background); delta=\(delta)")
                }
                XCTAssertLessThanOrEqual(delta, 8, "Wrong outside corner: \(headerID)")
            }
        }
        if !childIDs.isEmpty {
            // Scan both painted edges across ALL child intervals, including tools -> owner.
            // A text-only AX frame can leave normal white row padding between labels.
            let lastChild = app.buttons[childIDs[childIDs.count - 1]].frame
            for y in stride(from: headerFrame.maxY - 1, through: lastChild.minY + 2, by: 1) {
                for x in [leftX + 1, rightX - 1] {
                    XCTAssertLessThanOrEqual(distance(pixel(x, y), fill), 8, "Gray seam/internal corner at \(x),\(y): \(headerID)")
                }
            }
        }
    }

    func assertPaintedCardGap(_ app: XCUIApplication, before: XCUIElement, after: XCUIElement, expected: CGFloat) {
        let first = before.frame, second = after.frame
        XCTAssertEqual(second.minY, first.maxY + expected, accuracy: 1, "The real card boundaries must be separated by the stack spacing")
        guard let image = app.screenshot().image.cgImage else { return XCTFail("Missing card gap screenshot") }
        let scale = CGFloat(image.width) / app.frame.width
        func pixel(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            guard let crop = image.cropping(to: CGRect(x: x * scale, y: y * scale, width: 1, height: 1)) else { return [] }
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return bytes.prefix(3).map(Int.init)
        }
        func distance(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).map { abs($0 - $1) }.max() ?? 255 }
        let background = pixel(2, first.maxY)
        // Mid-card columns avoid both 10pt corners and the leading About text.
        for x in [first.midX, first.maxX - 14] {
            let fill = pixel(x, first.maxY - 3)
            XCTAssertGreaterThan(distance(fill, background), 8, "A visible card fill must bracket the gap")
            let start = Int((first.maxY - 2) * scale)
            let end = Int((second.minY + 3) * scale)
            let gray = (start...end).filter { distance(pixel(x, (CGFloat($0) + 0.5) / scale), background) <= 8 }
            XCTAssertEqual(CGFloat(gray.count) / scale, expected, accuracy: 1, "Painted card-to-card gap must stay 10pt, not AX-label padding")
            guard let low = gray.first, let high = gray.last else { XCTFail("Missing visible gap"); continue }
            XCTAssertEqual(gray.count, high - low + 1, "The visible gap must be one continuous background interval")
            XCTAssertEqual(CGFloat(low) / scale, first.maxY, accuracy: 1, "Appearance must end at its visible card boundary")
            XCTAssertEqual(CGFloat(high + 1) / scale, second.minY, accuracy: 1, "About background must start after its 10pt stack gap")
            XCTAssertLessThanOrEqual(distance(pixel(x, second.minY + 2), fill), 8, "About must paint its white/dark card after the gap")
        }
    }

    func disclosureHeaderBrightness(_ app: XCUIApplication, header: XCUIElement) -> Int {
        let headerFrame = header.frame
        guard let image = app.screenshot().image.cgImage else { XCTFail("Missing screenshot"); return 0 }
        let scale = CGFloat(image.width) / app.frame.width
        guard let crop = image.cropping(to: CGRect(x: (headerFrame.maxX - 8) * scale, y: headerFrame.midY * scale, width: 1, height: 1))
        else { XCTFail("Missing header fill"); return 0 }
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Int.init).reduce(0, +) / 3
    }

    func assertNeutralNavigationText(_ app: XCUIApplication, title: String, leadingIconWidth: CGFloat = 42) {
        let text = app.staticTexts[title].firstMatch
        XCTAssertTrue(text.exists, "Missing navigation title: \(title)")
        let frame = text.frame, appFrame = app.frame
        let screenshot = app.screenshot()
        guard !frame.isEmpty, appFrame.contains(frame), frame.width > 66,
              let image = screenshot.image.cgImage else { return XCTFail("Missing visible title: \(title)") }
        // RepositoryFeatureLabel's AX text spans the row: exclude its 30pt icon + 12pt gap and trailing chevron.
        let textFrame = CGRect(x: frame.minX + leadingIconWidth, y: frame.minY, width: frame.width - leadingIconWidth - 24, height: frame.height)
        let scale = CGFloat(image.width) / appFrame.width
        guard let crop = image.cropping(to: CGRect(x: textFrame.minX * scale, y: textFrame.minY * scale,
            width: textFrame.width * scale, height: textFrame.height * scale)) else { return XCTFail("Missing title crop") }
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        let background = bytes.prefix(3).map(Int.init).reduce(0, +) / 3
        var colored = 0, ink = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let rgb = bytes[i..<(i + 3)].map(Int.init)
            if rgb.max()! - rgb.min()! > 35 { colored += 1 }
            else if abs(rgb.reduce(0, +) / 3 - background) >= 128 { ink += 1 }
        }
        if colored != 0 || ink < 8 {
            for (name, attachment) in [
                ("navigation-color-screen-", XCTAttachment(screenshot: screenshot)),
                ("navigation-color-crop-", XCTAttachment(image: UIImage(cgImage: crop))),
                ("navigation-color-frame-", XCTAttachment(string: "AX=\(frame); text=\(textFrame); app=\(appFrame); scale=\(scale); colored=\(colored); ink=\(ink)"))
            ] {
                attachment.name = name + title; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        XCTAssertEqual(colored, 0, "Navigation title must use neutral text, not inherit link tint: \(title)")
        XCTAssertGreaterThanOrEqual(ink, 8, "Navigation title must visibly paint primary text: \(title)")
    }

    func assertVisibleThemeCheckmark(_ app: XCUIApplication, selectedTitle: String) {
        guard let image = app.screenshot().image.cgImage else { return XCTFail("Missing screenshot") }
        let scale = CGFloat(image.width) / app.frame.width
        for title in ["跟随系统", "浅色", "深色"] {
            let item = app.buttons[title]
            XCTAssertTrue(item.exists && item.isHittable)
            let frame = item.frame
            // UIKit paints a neutral checkmark before the menu title, not an accent trailing icon.
            let rect = CGRect(x: frame.minX + 4, y: frame.midY - 8, width: 24, height: 16)
            guard let crop = image.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale,
                width: rect.width * scale, height: rect.height * scale)) else { return XCTFail("Missing theme mark crop") }
            var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
                    bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            }
            let background = bytes.prefix(3).map(Int.init).reduce(0, +) / 3
            let ink = stride(from: 0, to: bytes.count, by: 4).filter { index in
                let rgb = bytes[index..<(index + 3)].map(Int.init)
                return abs(rgb.reduce(0, +) / 3 - background) > 70 && rgb.max()! - rgb.min()! < 50
            }.count
            if title == selectedTitle { XCTAssertGreaterThan(ink, 8, "The selected native action must actually paint its leading checkmark") }
            else { XCTAssertEqual(ink, 0, "The old row must erase its checkmark: \(title)") }
        }
    }
}
