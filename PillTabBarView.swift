import Cocoa

protocol PillTabBarDelegate: AnyObject {
    func tabBar(_ tabBar: PillTabBarView, didSelectTabAt index: Int)
    func tabBar(_ tabBar: PillTabBarView, didCloseTabAt index: Int)
    func tabBar(_ tabBar: PillTabBarView, didClickActiveTabAt index: Int)
}

class PillTabBarView: NSView {
    weak var delegate: PillTabBarDelegate?
    private var segments: [TabSegment] = []
    private(set) var activeIndex: Int = 0

    var barBackgroundColor: NSColor = NSColor.windowBackgroundColor {
        didSet { needsDisplay = true }
    }
    var activeSegmentColor: NSColor = NSColor.controlAccentColor {
        didSet { needsDisplay = true }
    }
    var textColor: NSColor = .labelColor {
        didSet { segments.forEach { $0.textColor = textColor } }
    }
    var activeTextColor: NSColor = .white {
        didSet { updateSegmentColors() }
    }
    var separatorColor: NSColor = NSColor.separatorColor {
        didSet { needsDisplay = true }
    }
    var activeTabRawMode: Bool = false {
        didSet { needsDisplay = true }
    }

    private let scrollView: NSScrollView
    private let stackView: NSStackView
    private let segmentHeight: CGFloat = 26
    private let barPadding: CGFloat = 4
    private let cornerRadius: CGFloat = 6
    private var hoverTrackingArea: NSTrackingArea?
    private var widthConstraint: NSLayoutConstraint?

    /// Called when mouse enters/exits the tab bar itself (for auto-hide coordination)
    var onMouseInside: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        scrollView = NSScrollView(frame: .zero)
        stackView = NSStackView(views: [])
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        scrollView = NSScrollView(frame: .zero)
        stackView = NSStackView(views: [])
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = false

        // Shadow for floating appearance
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.3).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        stackView.orientation = .horizontal
        stackView.spacing = 0
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stackView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: barPadding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -barPadding),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: barPadding),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -barPadding),
            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let barRect = bounds
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Background with subtle border
        barBackgroundColor.setFill()
        barPath.fill()

        NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
        barPath.lineWidth = 0.5
        barPath.stroke()

        // Active segment highlight
        if activeIndex < segments.count {
            let segment = segments[activeIndex]
            guard let segFrame = segment.superview?.convert(segment.frame, to: self) else { return }

            NSGraphicsContext.saveGraphicsState()
            barPath.addClip()

            let highlightColor = activeTabRawMode
                ? (NSColor.systemOrange)
                : activeSegmentColor
            let highlightRect = segFrame.insetBy(dx: 2, dy: 2)
            let highlightPath = NSBezierPath(roundedRect: highlightRect, xRadius: cornerRadius - 2, yRadius: cornerRadius - 2)
            highlightColor.setFill()
            highlightPath.fill()

            NSGraphicsContext.restoreGraphicsState()
        }

        // Dividers between inactive segments (skip around active)
        for i in 0..<(segments.count - 1) {
            if i == activeIndex || i + 1 == activeIndex { continue }

            let segment = segments[i]
            guard let segFrame = segment.superview?.convert(segment.frame, to: self) else { continue }

            let sepX = segFrame.maxX
            let sepTop = barRect.minY + 7
            let sepBottom = barRect.maxY - 7

            separatorColor.setStroke()
            let sepPath = NSBezierPath()
            sepPath.move(to: NSPoint(x: sepX, y: sepTop))
            sepPath.line(to: NSPoint(x: sepX, y: sepBottom))
            sepPath.lineWidth = 1
            sepPath.stroke()
        }
    }

    private func updateSegmentColors() {
        for (i, segment) in segments.enumerated() {
            segment.textColor = (i == activeIndex) ? activeTextColor : textColor
        }
    }

    func setTabs(_ files: [FileState], activeIndex: Int) {
        self.activeIndex = activeIndex
        if segments.count != files.count {
            segments.forEach { $0.removeFromSuperview() }
            segments = []
            for (i, file) in files.enumerated() {
                let segment = TabSegment(filename: file.url.lastPathComponent, index: i, isActive: i == activeIndex)
                segment.onSelect = { [weak self] idx in
                    guard let self = self else { return }
                    if idx == self.activeIndex {
                        self.delegate?.tabBar(self, didClickActiveTabAt: idx)
                    } else {
                        self.delegate?.tabBar(self, didSelectTabAt: idx)
                    }
                }
                segment.onClose = { [weak self] idx in
                    guard let self = self else { return }
                    self.delegate?.tabBar(self, didCloseTabAt: idx)
                }
                segments.append(segment)
                stackView.addArrangedSubview(segment)
            }
        } else {
            for (i, file) in files.enumerated() {
                segments[i].update(filename: file.url.lastPathComponent, index: i, isActive: i == activeIndex)
            }
        }
        updateSegmentColors()
        needsDisplay = true
        updateWidthConstraint()
    }

    private func updateWidthConstraint() {
        stackView.layoutSubtreeIfNeeded()
        let contentWidth = stackView.fittingSize.width + barPadding * 2
        let maxWidth: CGFloat = (superview?.bounds.width ?? 600) - 32
        let targetWidth = min(contentWidth, maxWidth)

        if let existing = widthConstraint {
            existing.constant = targetWidth
        } else {
            widthConstraint = widthAnchor.constraint(equalToConstant: targetWidth)
            widthConstraint?.isActive = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea { removeTrackingArea(existing) }
        hoverTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(hoverTrackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea == hoverTrackingArea {
            onMouseInside?(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea == hoverTrackingArea {
            onMouseInside?(false)
        }
    }

    func scrollToActiveTab() {
        guard activeIndex < segments.count else { return }
        let segment = segments[activeIndex]
        scrollView.contentView.scrollToVisible(segment.frame)
    }
}

class TabSegment: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var textColor: NSColor = .labelColor { didSet { label.textColor = textColor } }

    private let label: NSTextField
    private let closeButton: NSButton
    private var index: Int = 0
    private var trackingArea: NSTrackingArea?

    init(filename: String, index: Int, isActive: Bool) {
        self.index = index
        label = NSTextField(labelWithString: filename)
        closeButton = NSButton(title: "\u{2715}", target: nil, action: nil)
        super.init(frame: .zero)
        setupViews(filename: filename, isActive: isActive)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupViews(filename: String, isActive: Bool) {
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        addSubview(closeButton)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
        ])
        updateTrackingAreas()
    }

    func update(filename: String, index: Int, isActive: Bool) {
        self.index = index
        label.stringValue = filename
    }

    override func updateTrackingAreas() {
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if closeButton.frame.contains(location) { return }
        onSelect?(index)
    }

    @objc private func closeTapped() { onClose?(index) }
}
