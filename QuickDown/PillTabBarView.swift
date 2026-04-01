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

    var pillBackgroundColor: NSColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5) {
        didSet { needsDisplay = true }
    }
    var activeSegmentColor: NSColor = NSColor.controlAccentColor.withAlphaComponent(0.2) {
        didSet { needsDisplay = true }
    }
    var textColor: NSColor = .labelColor {
        didSet { segments.forEach { $0.textColor = textColor } }
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
    private let capsuleRadius: CGFloat = 13

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
        layer?.masksToBounds = true

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

        // All internal constraints at defaultHigh so they yield
        // when the bar is collapsed to height 0 (single-file mode)
        let constraints: [(NSLayoutConstraint, NSLayoutConstraint.Priority)] = [
            (scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: barPadding), .defaultHigh),
            (scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -barPadding), .defaultHigh),
            (scrollView.topAnchor.constraint(equalTo: topAnchor, constant: barPadding), .defaultHigh),
            (scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -barPadding), .defaultHigh),
            (stackView.topAnchor.constraint(equalTo: scrollView.topAnchor), .defaultHigh),
            (stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor), .defaultHigh),
            (stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor), .defaultHigh),
            (stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor), .defaultHigh),
        ]

        for (constraint, priority) in constraints {
            constraint.priority = priority
            constraint.isActive = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw the continuous capsule background
        let pillRect = bounds.insetBy(dx: 2, dy: 2)
        let capsulePath = NSBezierPath(roundedRect: pillRect, xRadius: capsuleRadius, yRadius: capsuleRadius)
        pillBackgroundColor.setFill()
        capsulePath.fill()

        // Draw the active segment highlight inside the capsule
        if activeIndex < segments.count {
            let segment = segments[activeIndex]
            // Convert segment frame to our coordinate space
            guard let segFrame = segment.superview?.convert(segment.frame, to: self) else { return }

            // Clip highlight to the capsule shape
            NSGraphicsContext.saveGraphicsState()
            capsulePath.addClip()

            let highlightColor = activeTabRawMode
                ? (activeSegmentColor.blended(withFraction: 0.3, of: NSColor.systemOrange) ?? activeSegmentColor)
                : activeSegmentColor
            let highlightPath = NSBezierPath(roundedRect: segFrame.insetBy(dx: 1, dy: 1), xRadius: capsuleRadius - 2, yRadius: capsuleRadius - 2)
            highlightColor.setFill()
            highlightPath.fill()

            NSGraphicsContext.restoreGraphicsState()
        }

        // Draw separators between inactive segments (skip around active)
        for i in 0..<(segments.count - 1) {
            // Skip separators adjacent to the active segment
            if i == activeIndex || i + 1 == activeIndex { continue }

            let segment = segments[i]
            guard let segFrame = segment.superview?.convert(segment.frame, to: self) else { continue }

            let sepX = segFrame.maxX
            let sepTop = pillRect.minY + 5
            let sepBottom = pillRect.maxY - 5

            separatorColor.setStroke()
            let sepPath = NSBezierPath()
            sepPath.move(to: NSPoint(x: sepX, y: sepTop))
            sepPath.line(to: NSPoint(x: sepX, y: sepBottom))
            sepPath.lineWidth = 1
            sepPath.stroke()
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
        segments.forEach { $0.textColor = textColor }
        needsDisplay = true
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
        // No per-segment background or rounding — the parent draws the capsule

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
