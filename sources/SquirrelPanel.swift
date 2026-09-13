//
//  SquirrelPanel.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import AppKit

final class SquirrelPanel: NSPanel {
  // macOS 27's whole-window Liquid Glass style mask is private SPI.
  private static let windowGlassStyleMaskBit = NSWindow.StyleMask(rawValue: UInt(1) << 36)

  private let view: SquirrelView
  private let back: NSView
  private let innerView: NSView
  let usesWindowGlass: Bool
  var inputController: SquirrelInputController?

  var position: NSRect
  private var screenRect: NSRect = .zero
  private var maxHeight: CGFloat = 0

  private var statusMessage: String = ""
  private var statusTimer: Timer?

  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var candidates: [String] = .init()
  private var comments: [String] = .init()
  private var labels: [String] = .init()
  private var index: Int = 0
  private var cursorIndex: Int = 0
  // Rime indices stay logical while candidateRanges uses visual indices.
  private var candidateOrderReversed = false
  private var pressedCandidateDisplayIndex: Int?
  private var scrollDirection: CGVector = .zero
  private var scrollTime: Date = .distantPast
  private var page: Int = 0
  private var lastPage: Bool = true
  private var pagingUp: Bool?
  private enum VisibilityState {
    case hidden, showing, visible, hiding
  }
  private var visibilityState: VisibilityState = .hidden
  private var visibilityAnimationID: UInt = 0
  // Whether the previous show() presented a status message rather than a
  // composition. Transitions between the two content modes must swap
  // instantly and must not share the memorized width.
  private var lastShowWasStatus = false

  init(position: NSRect, windowGlass: Bool = false) {
    self.position = position
    self.view = SquirrelView(frame: position)
    self.back = Self.makeBackgroundView()
    self.innerView = NSView()

    let useWindowGlass = windowGlass
      && ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    self.usesWindowGlass = useWindowGlass

    var styleMask: NSWindow.StyleMask = .nonactivatingPanel
    if useWindowGlass {
      styleMask.insert(Self.windowGlassStyleMaskBit)
      // AppKit uses this regular frame class for the full Liquid Glass rim.
      styleMask.insert(.titled)
      styleMask.insert(.closable)
      styleMask.insert(.fullSizeContentView)
    }

    super.init(contentRect: position, styleMask: styleMask, backing: .buffered, defer: true)
    self.level = .init(Int(CGShieldingWindowLevel()))
    // The candidate panel resizes on almost every keystroke; window-level
    // implicit animations (including the glass frame morph) must never run.
    self.animationBehavior = .none
    // Match the glass demo: keep the system window shadow off so it does not
    // appear as a black outline around the non-activating input panel.
    self.hasShadow = false
    self.isOpaque = false
    self.backgroundColor = .clear
    if useWindowGlass {
      titleVisibility = .hidden
      titlebarAppearsTransparent = true
      titlebarSeparatorStyle = .none
      isMovable = false
      for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
        standardWindowButton(button)?.isHidden = true
      }
    }

    view.isGlassBackground = useWindowGlass
    back.wantsLayer = true
    back.layer?.mask = view.shape
    innerView.wantsLayer = true
    innerView.addSubview(back)
    innerView.addSubview(view)
    innerView.addSubview(view.textView)

    let contentView = NSView()
    contentView.wantsLayer = true
    contentView.addSubview(innerView)
    self.contentView = contentView
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  var linear: Bool {
    view.currentTheme.linear
  }
  var vertical: Bool {
    view.currentTheme.vertical
  }
  var inlinePreedit: Bool {
    view.currentTheme.inlinePreedit
  }
  var inlineCandidate: Bool {
    view.currentTheme.inlineCandidate
  }
  // When the panel is above the caret, stacked candidates are rendered in
  // reverse order so candidate 1 stays closest to the caret. Rime still
  // receives logical candidate navigation, so the vertical keys must be
  // swapped to preserve their on-screen direction.
  var reversesVerticalCandidateNavigation: Bool {
    candidateOrderReversed && !linear && !vertical
  }

  private func logicalCandidateIndex(forDisplayIndex displayIndex: Int) -> Int? {
    guard displayIndex >= 0 && displayIndex < candidates.count else { return nil }
    return candidateOrderReversed ? candidates.count - 1 - displayIndex : displayIndex
  }

  private func displayCandidateIndex(forLogicalIndex logicalIndex: Int) -> Int? {
    guard logicalIndex >= 0 && logicalIndex < candidates.count else { return nil }
    return candidateOrderReversed ? candidates.count - 1 - logicalIndex : logicalIndex
  }

  // swiftlint:disable:next cyclomatic_complexity
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      let (index, _, pagingUp) =  view.click(at: mousePosition())
      if let pagingUp {
        self.pagingUp = pagingUp
      } else {
        self.pagingUp = nil
      }
      if let index, logicalCandidateIndex(forDisplayIndex: index) != nil {
        pressedCandidateDisplayIndex = index
      } else {
        pressedCandidateDisplayIndex = nil
      }
    case .leftMouseUp:
      let (index, preeditIndex, pagingUp) = view.click(at: mousePosition())

      if let pagingUp, pagingUp == self.pagingUp {
        _ = inputController?.page(up: pagingUp)
      } else {
        self.pagingUp = nil
      }
      if let preeditIndex, preeditIndex >= 0 && preeditIndex < preedit.utf16.count {
        if preeditIndex < caretPos {
          _ = inputController?.moveCaret(forward: true)
        } else if preeditIndex > caretPos {
          _ = inputController?.moveCaret(forward: false)
        }
      }
      if let displayIndex = index,
         displayIndex == pressedCandidateDisplayIndex,
         let logicalIndex = logicalCandidateIndex(forDisplayIndex: displayIndex) {
        _ = inputController?.selectCandidate(logicalIndex)
      }
      pressedCandidateDisplayIndex = nil
    case .mouseEntered:
      acceptsMouseMovedEvents = true
    case .mouseExited:
      acceptsMouseMovedEvents = false
      pressedCandidateDisplayIndex = nil
      if cursorIndex != index {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
      pagingUp = nil
    case .mouseMoved:
      let (displayIndex, _, _) = view.click(at: mousePosition())
      if let displayIndex,
         let logicalIndex = logicalCandidateIndex(forDisplayIndex: displayIndex),
         cursorIndex != logicalIndex {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: logicalIndex, page: page, lastPage: lastPage, update: false)
      }
    case .scrollWheel:
      if event.phase == .began {
        scrollDirection = .zero
      } else if event.phase == .ended || (event.phase == .init(rawValue: 0) && event.momentumPhase != .init(rawValue: 0)) {
        if abs(scrollDirection.dx) > abs(scrollDirection.dy) && abs(scrollDirection.dx) > 10 {
          _ = inputController?.page(up: (scrollDirection.dx < 0) == vertical)
        } else if abs(scrollDirection.dx) < abs(scrollDirection.dy) && abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
        }
        scrollDirection = .zero
      } else if event.phase == .init(rawValue: 0) && event.momentumPhase == .init(rawValue: 0) {
        if scrollTime.timeIntervalSinceNow < -1 {
          scrollDirection = .zero
        }
        scrollTime = .now
        if (scrollDirection.dy >= 0 && event.scrollingDeltaY > 0) || (scrollDirection.dy <= 0 && event.scrollingDeltaY < 0) {
          scrollDirection.dy += event.scrollingDeltaY
        } else {
          scrollDirection = .zero
        }
        if abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
          scrollDirection = .zero
        }
      } else {
        scrollDirection.dx += event.scrollingDeltaX
        scrollDirection.dy += event.scrollingDeltaY
      }
    default:
      break
    }
    super.sendEvent(event)
  }

  func hide() {
    statusTimer?.invalidate()
    statusTimer = nil
    maxHeight = 0
    candidateOrderReversed = false
    pressedCandidateDisplayIndex = nil

    guard isVisible else {
      visibilityState = .hidden
      return
    }
    animateVisibility(visible: false)
  }

  private func animateVisibility(visible: Bool) {
    guard let layer = innerView.layer else {
      if !visible {
        orderOut(nil)
        visibilityState = .hidden
      }
      return
    }

    visibilityAnimationID &+= 1
    let animationID = visibilityAnimationID

    // Retarget from the presentation state so a show/hide reversal never
    // jumps back to a stale endpoint.
    let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
    let currentTransform = layer.presentation()?.transform ?? layer.transform
    layer.removeAllAnimations()

    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let targetOpacity: Float = visible ? 1 : 0
    let targetTransform = visible
      ? CATransform3DIdentity
      : CATransform3DMakeScale(0.985, 0.985, 1)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = targetOpacity
    layer.transform = targetTransform
    if reduceMotion {
      CATransaction.commit()
      visibilityState = visible ? .visible : .hidden
      if !visible {
        orderOut(nil)
      }
      return
    }

    visibilityState = visible ? .showing : .hiding
    CATransaction.setCompletionBlock { [weak self] in
      guard let self, self.visibilityAnimationID == animationID else { return }
      self.visibilityState = visible ? .visible : .hidden
      if !visible {
        self.orderOut(nil)
      }
    }
    let duration = visible ? 0.14 : 0.1
    let timingFunction = CAMediaTimingFunction(name: .easeOut)

    let opacityAnimation = CABasicAnimation(keyPath: "opacity")
    opacityAnimation.fromValue = currentOpacity
    opacityAnimation.toValue = targetOpacity
    opacityAnimation.duration = duration
    opacityAnimation.timingFunction = timingFunction

    let transformAnimation = CABasicAnimation(keyPath: "transform")
    transformAnimation.fromValue = NSValue(caTransform3D: currentTransform)
    transformAnimation.toValue = NSValue(caTransform3D: targetTransform)
    transformAnimation.duration = duration
    transformAnimation.timingFunction = timingFunction

    layer.add(opacityAnimation, forKey: "squirrel.visibility.opacity")
    layer.add(transformAnimation, forKey: "squirrel.visibility.transform")
    CATransaction.commit()
  }

  // swiftlint:disable:next cyclomatic_complexity function_parameter_count
  func update(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted index: Int, page: Int, lastPage: Bool, update: Bool) {
    if update {
      self.preedit = preedit
      self.selRange = selRange
      self.caretPos = caretPos
      self.candidates = candidates
      self.comments = comments
      self.labels = labels
      self.index = index
      self.page = page
      self.lastPage = lastPage
    }
    cursorIndex = index

    if !candidates.isEmpty || !preedit.isEmpty {
      statusMessage = ""
      statusTimer?.invalidate()
      statusTimer = nil
    } else {
      candidateOrderReversed = false
      view.preeditAtBottom = false
      if !statusMessage.isEmpty {
        show(status: statusMessage)
        statusMessage = ""
      } else if statusTimer == nil {
        hide()
      }
      return
    }

    let theme = view.currentTheme
    currentScreen()
    renderCurrentText(highlighted: index, theme: theme)
    show()
  }

  func updateStatus(long longMessage: String, short shortMessage: String) {
    let theme = view.currentTheme
    switch theme.statusMessageType {
    case .mix:
      statusMessage = shortMessage.isEmpty ? longMessage : shortMessage
    case .long:
      statusMessage = longMessage
    case .short:
      if !shortMessage.isEmpty {
        statusMessage = shortMessage
      } else if let initial = longMessage.first {
        statusMessage = String(initial)
      } else {
        statusMessage = ""
      }
    }
  }

  func load(config: SquirrelConfig, forDarkMode isDark: Bool) {
    if isDark {
      view.darkTheme = SquirrelTheme()
      view.darkTheme.load(config: config, dark: true)
    } else {
      view.lightTheme = SquirrelTheme()
      view.lightTheme.load(config: config, dark: isDark)
    }
  }
}

private extension SquirrelPanel {
  func renderCurrentText(highlighted index: Int, theme: SquirrelTheme) {
    let text = NSMutableAttributedString()
    let preeditAtBottom = candidateOrderReversed && !preedit.isEmpty && !candidates.isEmpty
    view.preeditAtBottom = preeditAtBottom

    var preeditRange = NSRange.empty
    var highlightedPreeditRange = NSRange.empty

    func appendPreedit() {
      guard !preedit.isEmpty else { return }
      let localRange = NSRange(location: 0, length: preedit.utf16.count)
      preeditRange = NSRange(location: text.length, length: localRange.length)
      highlightedPreeditRange = NSRange(location: text.length + selRange.location, length: selRange.length)

      let line = NSMutableAttributedString(string: preedit)
      line.addAttributes(theme.preeditAttrs, range: localRange)
      line.addAttributes(theme.preeditHighlightedAttrs, range: selRange)
      text.append(line)
      text.addAttribute(.paragraphStyle, value: theme.preeditParagraphStyle, range: preeditRange)
    }

    if !preeditAtBottom {
      appendPreedit()
      if !preedit.isEmpty && !candidates.isEmpty {
        text.append(NSAttributedString(string: "\n", attributes: theme.preeditAttrs))
      }
    }

    var candidateRanges = [NSRange]()
    let displayOrder = candidateOrderReversed ? Array(candidates.indices.reversed()) : Array(candidates.indices)
    for (displayIndex, logicalIndex) in displayOrder.enumerated() {
      let isHighlighted = logicalIndex == index
      let attrs = isHighlighted ? theme.highlightedAttrs : theme.attrs
      let labelAttrs = isHighlighted ? theme.labelHighlightedAttrs : theme.labelAttrs
      let commentAttrs = isHighlighted ? theme.commentHighlightedAttrs : theme.commentAttrs

      let label = if theme.candidateFormat.contains(/\[label\]/) {
        if labels.count > 1 && logicalIndex < labels.count {
          labels[logicalIndex]
        } else if labels.count == 1 && logicalIndex < labels.first!.count {
          String(labels.first![labels.first!.index(labels.first!.startIndex, offsetBy: logicalIndex)])
        } else {
          "\(logicalIndex + 1)"
        }
      } else {
        ""
      }

      let candidate = candidates[logicalIndex].precomposedStringWithCanonicalMapping
      let comment = comments[logicalIndex].precomposedStringWithCanonicalMapping
      let line = NSMutableAttributedString(string: theme.candidateFormat, attributes: labelAttrs)
      for range in line.string.ranges(of: /\[candidate\]/) {
        let convertedRange = convert(range: range, in: line.string)
        line.addAttributes(attrs, range: convertedRange)
        if candidate.count <= 5 {
          line.addAttribute(.noBreak, value: true, range: NSRange(location: convertedRange.location + 1, length: convertedRange.length - 1))
        }
      }
      for range in line.string.ranges(of: /\[comment\]/) {
        let convertedRange = convert(range: range, in: line.string)
        // Apply semantic accent/warning colors only for non-highlighted rows.
        if let inputController, !inputController.specialCommentIndices.isEmpty && !isHighlighted {
          var newCommentAttrs = commentAttrs
          if let accent = inputController.specialCommentIndices[.commentHighlight], accent.contains(logicalIndex) {
            newCommentAttrs[.foregroundColor] = theme.accentCommentTextColor
          } else if let warning = inputController.specialCommentIndices[.commentWarning], warning.contains(logicalIndex) {
            newCommentAttrs[.foregroundColor] = theme.warningCommentTextColor
          }
          line.addAttributes(newCommentAttrs, range: convertedRange)
        } else {
          line.addAttributes(commentAttrs, range: convertedRange)
        }
      }
      line.mutableString.replaceOccurrences(of: "[label]", with: label, range: NSRange(location: 0, length: line.length))
      let labeledLine = line.copy() as! NSAttributedString
      line.mutableString.replaceOccurrences(of: "[candidate]", with: candidate, range: NSRange(location: 0, length: line.length))
      line.mutableString.replaceOccurrences(of: "[comment]", with: comment, range: NSRange(location: 0, length: line.length))

      if line.length <= 10 {
        line.addAttribute(.noBreak, value: true, range: NSRange(location: 1, length: line.length - 1))
      }

      let lineSeparator = NSAttributedString(string: linear ? "  " : "\n", attributes: attrs)
      if displayIndex > 0 {
        text.append(lineSeparator)
      }
      let str = lineSeparator.mutableCopy() as! NSMutableAttributedString
      if vertical {
        str.addAttribute(.verticalGlyphForm, value: 1, range: NSRange(location: 0, length: str.length))
      }
      view.separatorWidth = str.boundingRect(with: .zero).width

      let paragraphStyleCandidate = (displayIndex == 0 ? theme.firstParagraphStyle : theme.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
      if linear {
        paragraphStyleCandidate.paragraphSpacingBefore -= theme.linespace
        paragraphStyleCandidate.lineSpacing = theme.linespace
      }
      if !linear, let labelEnd = labeledLine.string.firstMatch(of: /\[(candidate|comment)\]/)?.range.lowerBound {
        let labelString = labeledLine.attributedSubstring(from: NSRange(location: 0, length: labelEnd.utf16Offset(in: labeledLine.string)))
        let labelWidth = labelString.boundingRect(with: .zero, options: [.usesLineFragmentOrigin]).width
        paragraphStyleCandidate.headIndent = labelWidth
      }
      line.addAttribute(.paragraphStyle, value: paragraphStyleCandidate, range: NSRange(location: 0, length: line.length))

      candidateRanges.append(NSRange(location: text.length, length: line.length))
      text.append(line)
    }

    if preeditAtBottom {
      if !text.string.isEmpty {
        text.append(NSAttributedString(string: "\n", attributes: theme.preeditAttrs))
      }
      appendPreedit()
    }

    view.textView.textContentStorage?.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)

    // Force TextKit 2 layout before measuring wrapped text and highlight bounds.
    let textWidth = maxTextWidth()
    let maxTextHeight = vertical ? screenRect.width - theme.edgeInset.width * 2 : screenRect.height - theme.edgeInset.height * 2
    view.textContainer.size = NSSize(width: textWidth, height: maxTextHeight)
    view.textLayoutManager.ensureLayout(for: view.textLayoutManager.documentRange)
    view.textView.scrollToBeginningOfDocument(nil)
    view.drawView(candidateRanges: candidateRanges,
                  hilightedIndex: displayCandidateIndex(forLogicalIndex: index) ?? -1,
                  preeditRange: preeditRange,
                  highlightedPreeditRange: highlightedPreeditRange,
                  canPageUp: page > 0,
                  canPageDown: !lastPage)
  }

  func mousePosition() -> NSPoint {
    var point = NSEvent.mouseLocation
    point = self.convertPoint(fromScreen: point)
    return view.convert(point, from: nil)
  }

  func currentScreen() {
    if let screen = NSScreen.main {
      screenRect = screen.frame
    }
    for screen in NSScreen.screens where screen.frame.contains(position.origin) {
      screenRect = screen.frame
      break
    }
  }

  func maxTextWidth() -> CGFloat {
    let theme = view.currentTheme
    let font: NSFont = theme.font
    let fontScale = font.pointSize / 12
    let textWidthRatio = min(1, 1 / (vertical ? 4 : 3) + fontScale / 12)
    let maxWidth = if vertical {
      screenRect.height * textWidthRatio - theme.edgeInset.height * 2
    } else {
      screenRect.width * textWidthRatio - theme.edgeInset.width * 2
    }
    return maxWidth
  }

  // swiftlint:disable:next cyclomatic_complexity
  func show() {
    let wasVisible = isVisible
    currentScreen()
    let theme = view.currentTheme
    if theme.native || view.darkTheme.available {
      self.appearance = NSApp.effectiveAppearance
    } else {
      // user configured only a light theme, set window appearance to light.
      self.appearance = NSAppearance(named: .aqua)
    }

    view.textView.textContainerInset = theme.edgeInset

    var naturalPanelSize = NSSize.zero
    var panelRect = NSRect.zero
    var requiresFullScreen = false
    var panelAboveCaret = false

    // Status messages (e.g. the Shift ASCII-mode toast) and composition
    // panels are different content modes: they must not share the memorized
    // width, and switching between them swaps instantly instead of morphing.
    let showingStatus = candidates.isEmpty && preedit.isEmpty
    if showingStatus != lastShowWasStatus {
      maxHeight = 0
    }

    // Candidate order can depend on the final side of the caret. Resolve that
    // state before touching the window so a single input update has only one
    // visible frame transaction.
    for layoutPass in 0...1 {
      var textWidth = maxTextWidth()
      view.textContainer.size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
      view.textContainer.widthTracksTextView = false
      view.textContainer.heightTracksTextView = false
      view.textLayoutManager.ensureLayout(for: view.textLayoutManager.documentRange)
      view.textView.bounds.origin = .zero

      var contentRect = view.contentRect
      if vertical {
        naturalPanelSize.width = contentRect.height + theme.edgeInset.height * 2
        naturalPanelSize.height = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
      } else {
        naturalPanelSize.width = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
        naturalPanelSize.height = contentRect.height + theme.edgeInset.height * 2
      }

      let maxAllowedWidth = screenRect.width * 0.95
      let maxAllowedHeight = screenRect.height * 0.95
      requiresFullScreen = naturalPanelSize.width > maxAllowedWidth || naturalPanelSize.height > maxAllowedHeight

      if requiresFullScreen {
        let area = contentRect.width * contentRect.height
        let screenRatio = maxAllowedWidth / maxAllowedHeight
        let optimalTextWidth = vertical ? sqrt(area / screenRatio) : sqrt(area * screenRatio)
        if optimalTextWidth > textWidth {
          textWidth = optimalTextWidth
          view.textContainer.size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
          view.textLayoutManager.ensureLayout(for: view.textLayoutManager.documentRange)
          contentRect = view.contentRect
          if vertical {
            naturalPanelSize.width = contentRect.height + theme.edgeInset.height * 2
            naturalPanelSize.height = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
          } else {
            naturalPanelSize.width = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
            naturalPanelSize.height = contentRect.height + theme.edgeInset.height * 2
          }
        }
      }

      if requiresFullScreen {
        let scaleX = maxAllowedWidth / naturalPanelSize.width
        let scaleY = maxAllowedHeight / naturalPanelSize.height
        let scale = min(scaleX, scaleY)
        panelRect.size = NSSize(width: naturalPanelSize.width * scale, height: naturalPanelSize.height * scale)
        panelRect.origin = NSPoint(
          x: screenRect.minX + (screenRect.width - panelRect.width) / 2,
          y: screenRect.minY + (screenRect.height - panelRect.height) / 2
        )
        maxHeight = 0
      } else {
        if theme.memorizeSize && (vertical && position.midY / screenRect.height < 0.5) ||
            (vertical && position.minX + max(contentRect.width, maxHeight) + theme.edgeInset.width * 2 > screenRect.maxX) {
          if contentRect.width >= maxHeight {
            maxHeight = contentRect.width
          } else {
            contentRect.size.width = maxHeight
            if vertical {
              naturalPanelSize.height = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
            } else {
              naturalPanelSize.width = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
            }
          }
        }

        // The whole-window Liquid Glass surface is re-rendered by the window
        // server on every frame change, racing against the app's content
        // update. Below the caret the backdrop also repaints on each key, so
        // width flutter shows up as random flicker. Quantize the width into
        // coarse buckets, tracked in both directions: the panel follows the
        // content in real time (growing and shrinking through the animated
        // morph) while sub-quantum flutter never touches the window frame.
        // Status toasts keep their natural size: they show once and do not
        // resize while visible.
        if usesWindowGlass && theme.memorizeSize && !vertical && !showingStatus {
          let widthQuantum: CGFloat = 20
          let quantizedWidth = (contentRect.width / widthQuantum).rounded(.up) * widthQuantum
          contentRect.size.width = quantizedWidth
          naturalPanelSize.width = contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset
        }

        // TextKit 2 can report fractional line bounds that differ by a small
        // amount after each marked-text update. Those fractions still cause a
        // whole-window Liquid Glass panel to resize. Snap only stacked
        // composition panels to the backing scale; a real row addition or
        // removal remains a real size change.
        if usesWindowGlass && !linear && !vertical && !showingStatus {
          let scale = max(backingScaleFactor, 1)
          naturalPanelSize.height = ceil(naturalPanelSize.height * scale) / scale
        }

        panelRect.size = naturalPanelSize
        if vertical {
          if position.midY / screenRect.height >= 0.5 {
            panelRect.origin.y = position.minY - SquirrelTheme.offsetHeight - panelRect.height + theme.pagingOffset
          } else {
            panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
          }
          panelRect.origin.x = position.minX - panelRect.width - SquirrelTheme.offsetHeight
          if view.preeditRange.length > 0, let preeditTextRange = view.convert(range: view.preeditRange) {
            let preeditRect = view.contentRect(range: preeditTextRange)
            panelRect.origin.x += preeditRect.height + theme.edgeInset.width
          }
        } else {
          panelRect.origin = NSPoint(x: position.minX - theme.pagingOffset, y: position.minY - SquirrelTheme.offsetHeight - panelRect.height)
        }

        if panelRect.maxX > screenRect.maxX { panelRect.origin.x = screenRect.maxX - panelRect.width }
        if panelRect.minX < screenRect.minX { panelRect.origin.x = screenRect.minX }
        if panelRect.minY < screenRect.minY {
          if vertical { panelRect.origin.y = screenRect.minY } else { panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight }
        }
        if panelRect.maxY > screenRect.maxY { panelRect.origin.y = screenRect.maxY - panelRect.height }
        if panelRect.minY < screenRect.minY { panelRect.origin.y = screenRect.minY }
      }

      let panelIsAboveCaret: Bool
      if requiresFullScreen {
        panelIsAboveCaret = false
      } else if panelRect.minY >= position.maxY {
        panelIsAboveCaret = true
      } else if panelRect.maxY <= position.minY {
        panelIsAboveCaret = false
      } else {
        panelIsAboveCaret = panelRect.midY > position.midY
      }
      panelAboveCaret = panelIsAboveCaret
      let wantsReversedCandidates = !candidates.isEmpty
        && !linear
        && !vertical
        && theme.candidateListReversedAboveCursor
        && panelIsAboveCaret
      if wantsReversedCandidates != candidateOrderReversed && layoutPass == 0 {
        candidateOrderReversed = wantsReversedCandidates
        renderCurrentText(highlighted: cursorIndex, theme: theme)
        continue
      }
      break
    }

    // The outer content view is managed by NSWindow. Keep natural text
    // coordinates and vertical rotation on the inner content view instead.
    innerView.frame = NSRect(origin: .zero, size: panelRect.size)
    innerView.bounds = NSRect(origin: .zero, size: naturalPanelSize)

    if vertical {
      innerView.boundsRotation = -90
      innerView.setBoundsOrigin(NSPoint(x: 0, y: naturalPanelSize.width))
    } else {
      innerView.boundsRotation = 0
      innerView.setBoundsOrigin(.zero)
    }

    view.textView.boundsRotation = 0
    view.textView.setBoundsOrigin(.zero)

    // Subviews must read the post-rotation bounds; Cocoa adjusts the origin and swaps dimensions in vertical mode.
    let subviewFrame = innerView.bounds
    view.frame = subviewFrame

    var textFrame = subviewFrame
    textFrame.size.width -= theme.pagingOffset
    textFrame.origin.x += theme.pagingOffset
    view.textView.frame = textFrame

    // All view geometry above is final before the window frame moves.
    //
    // Whole-window Liquid Glass is composited by the window server, so a
    // discrete frame change can never be made fully atomic with the content
    // update from the app side; a single mistimed tick reads as flicker.
    // Instead of fighting that race, animate frame changes of the visible
    // glass panel over a short morph (the same approach Apple's own Tahoe
    // candidate window and vChewing use); a one-tick offset inside continuous
    // motion is imperceptible.
    let frameChanged = frame != panelRect
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    // Morph only between two composition layouts. A status toast replacing a
    // candidate panel (or vice versa) is new content, not a resize: animating
    // it would visibly grow the panel out of the toast's small frame.
    let animateFrame = usesWindowGlass && wasVisible && frameChanged && !reduceMotion
      && !showingStatus && showingStatus == lastShowWasStatus

    // During the morph the content view must stay glued to the caret-facing
    // edge. Below the caret that edge is the top, and Cocoa windows anchor at
    // the bottom-left, so pre-offset the inner view and let autoresizing pull
    // it to origin zero as the window height settles.
    if animateFrame && !vertical && !panelAboveCaret {
      innerView.autoresizingMask = [.minYMargin]
      innerView.frame.origin.y = frame.height - panelRect.height
    } else {
      innerView.autoresizingMask = []
      innerView.frame.origin.y = 0
    }

    // If the compositor ever catches one tick of stale layer contents against
    // new geometry, keep those stale pixels glued to the caret-facing edge
    // instead of letting the default placement stretch them across the panel
    // (the classic live-resize "trembling" artifact).
    if frameChanged {
      let placement: NSView.LayerContentsPlacement =
        (!vertical && !panelAboveCaret) ? .topLeft : .bottomLeft
      for anchored in [contentView, innerView, view, view.textView] {
        anchored?.layerContentsPlacement = placement
      }
    }

    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = 0
    NSAnimationContext.current.allowsImplicitAnimation = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if usesWindowGlass {
      // The window frame supplies the Liquid Glass surface. Keeping the
      // fallback backdrop hidden avoids compositing two glass materials.
      back.isHidden = true
    } else if theme.translucency {
      var backFrame = subviewFrame
      backFrame.size.width += theme.pagingOffset
      back.frame = backFrame
      back.appearance = NSApp.effectiveAppearance
      back.isHidden = false
    } else {
      back.isHidden = true
    }
    alphaValue = theme.alpha
    if usesWindowGlass && wasVisible && frameChanged {
      // AppKit may re-evaluate the (non-key) panel's appearance around frame
      // changes. Assert the active glass state *before* the fenced present so
      // the material renders once, in its final state. Poking the glass after
      // the present would be a second, unfenced visual update per keystroke.
      assertActiveGlassState()
    }
    CATransaction.commit()
    // Keep setFrame outside any explicit CATransaction: AppKit sets up its own
    // geometry/drawing fence inside setFrame(display: true), and a nested
    // open transaction defers the content commit past that pairing.
    //
    // NSAnimationContext.runAnimationGroup is Apple's documented replacement
    // for NSDisableScreenUpdates "when a stronger than normal need for visual
    // atomicity is required" (NSGraphics.h deprecation note), so both the
    // animated and the instant presents go through it.
    if frameChanged {
      if animateFrame {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.12
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          context.allowsImplicitAnimation = true
          animator().setFrame(panelRect, display: true)
        }
      } else {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0
          context.allowsImplicitAnimation = false
          setFrame(panelRect, display: true)
        }
      }
    } else if view.needsDisplay {
      displayIfNeeded()
    }
    NSAnimationContext.endGrouping()

    invalidateShadow()
    let needsPresentationAnimation = !wasVisible || visibilityState == .hiding
    if !wasVisible {
      // The window is ordered in with its final geometry; only the content
      // layer starts offset and transparent, so Glass never animates a frame
      // resize during the appearance transition.
      let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      if reduceMotion {
        innerView.layer?.removeAllAnimations()
        innerView.layer?.opacity = 1
        innerView.layer?.transform = CATransform3DIdentity
        visibilityState = .visible
      } else {
        innerView.layer?.removeAllAnimations()
        innerView.layer?.opacity = 0
        innerView.layer?.transform = CATransform3DMakeScale(0.985, 0.985, 1)
        visibilityState = .hidden
      }
    }
    if !usesWindowGlass || !wasVisible {
      orderFront(nil)
    }
    if usesWindowGlass && !wasVisible {
      // The glass backing view exists only after the window is ordered in;
      // the full refresh is needed just once per appearance on screen.
      applyActiveGlassAppearance()
    }
    if needsPresentationAnimation && (!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || visibilityState == .hiding) {
      animateVisibility(visible: true)
    }
    lastShowWasStatus = showingStatus
    // voila!
  }

  func show(status message: String) {
    let theme = view.currentTheme
    let text = NSMutableAttributedString(string: message, attributes: theme.attrs)
    text.addAttribute(.paragraphStyle, value: theme.paragraphStyle, range: NSRange(location: 0, length: text.length))
    view.textContentStorage.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: [NSRange(location: 0, length: text.length)], hilightedIndex: -1,
                  preeditRange: .empty, highlightedPreeditRange: .empty, canPageUp: false, canPageDown: false)
    show()

    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: SquirrelTheme.showStatusDuration, repeats: false) { _ in
      self.hide()
    }
  }

  func convert(range: Range<String.Index>, in string: String) -> NSRange {
    let startPos = range.lowerBound.utf16Offset(in: string)
    let endPos = range.upperBound.utf16Offset(in: string)
    return NSRange(location: startPos, length: endPos - startPos)
  }

  // Idempotent state asserts, cheap enough to run before every fenced
  // present. These are private selectors used defensively at runtime.
  private func assertActiveGlassState() {
    let activeSelector = NSSelectorFromString("_setHasActiveAppearance:")
    if responds(to: activeSelector) {
      let method = unsafeBitCast(
        (self as NSObject).method(for: activeSelector),
        to: (@convention(c) (NSObject, Selector, Bool) -> Void).self)
      method(self, activeSelector, true)
    }

    let acquireSelector = NSSelectorFromString("acquireKeyAppearance")
    if responds(to: acquireSelector) {
      perform(acquireSelector)
    }
  }

  // Ask macOS to render a non-key input panel with the active Liquid Glass
  // appearance, forcing the glass backing view to refresh. Heavier than
  // assertActiveGlassState; used once per appearance on screen.
  private func applyActiveGlassAppearance() {
    assertActiveGlassState()

    let refreshSelector = NSSelectorFromString("_windowChangedKeyState")
    let glassSelector = NSSelectorFromString("_glassWindowBackingGlassView")
    if responds(to: glassSelector),
       let glass = perform(glassSelector)?.takeUnretainedValue() as? NSView,
       glass.responds(to: refreshSelector) {
      glass.perform(refreshSelector)
    }
    if responds(to: refreshSelector) {
      perform(refreshSelector)
    }
    if let frameView = contentView?.superview, frameView.responds(to: refreshSelector) {
      frameView.perform(refreshSelector)
    }
  }

  static func makeBackgroundView() -> NSView {
    if #available(macOS 26.0, *) {
      let glassView = NSGlassEffectView()
      glassView.style = .regular
      // glassView.translatesAutoresizingMaskIntoConstraints = false
      // glassView.cornerRadius = 100
      return glassView
    } else {
      let visualEffectView = NSVisualEffectView()
      visualEffectView.blendingMode = .behindWindow
      visualEffectView.material = .hudWindow
      visualEffectView.state = .active
      return visualEffectView
    }
  }
}
