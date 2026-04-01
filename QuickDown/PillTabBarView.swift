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
        didSet { needsDisplay = true; updateSegmentColors() }
    }
    var activeSegmentColor: NSColor = NSColor.controlAccentColor.withAlphaComponent(0.2) {
        didSet { updateSegmentColors() }
    }
    var textColor: NSColor = .labelColor {
        didSet { updateSegmentColors() }
    }
    var separatorColor: NSColor = NSColor.separatorColor {
        didSet { needsDisplay = true }
    }
    var activeTabRawMode: Bool = false {
        didSet { updateSegmentColors() }
    }

    private let scrollView: NSScrollView
    private let stackView: NSStackView
    private let segmentHeight: CGFloat = 26
    private let barPadding: CGFloat = 4

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
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        stackView.orientation = .horizontal
        stackView.spacing = 1
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stackView

        let top = scrollView.topAnchor.constraint(equalTo: topAnchor, constant: barPadding)
        let bottom = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -barPadding)
        // Lower priority so internal padding yields when the bar is collapsed to height 0
        top.priority = .defaultHigh
        bottom.priority = .defaultHigh

        let stackHeight = stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        stackHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: barPadding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -barPadding),
            top,
            bottom,
            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackHeight,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let pillRect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: pillRect, xRadius: segmentHeight / 2, yRadius: segmentHeight / 2)
        pillBackgroundColor.setFill()
        path.fill()
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
    }

    private func updateSegmentColors() {
        for (i, segment) in segments.enumerated() {
            if i == activeIndex {
                segment.backgroundColor = activeTabRawMode
                    ? activeSegmentColor.blended(withFraction: 0.3, of: NSColor.systemOrange) ?? activeSegmentColor
                    : activeSegmentColor
            } else {
                segment.backgroundColor = .clear
            }
            segment.textColor = textColor
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
    var backgroundColor: NSColor = .clear { didSet { needsDisplay = true } }
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
        wantsLayer = true
        layer?.cornerRadius = 12

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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if backgroundColor != .clear {
            let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
            backgroundColor.setFill()
            path.fill()
        }
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
