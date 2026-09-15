# 候选面板抖动问题分析与修复

> 适用范围：`style/liquid_enable: true` 且 `style/glass_window: true`（窗口级 Liquid Glass，macOS 27+）

## 1. 症状

打字过程中候选面板持续抖动，尤以文字最为明显。表现特征：

- **只在 `liquid_enable` 与 `glass_window` 同时开启时出现**，关掉任意一个即消失
- 面板位于光标**下方**时抖动明显，位于**上方**时相对正常
- 感觉上与面板尺寸变化相关（例如输入 `lwt`、`uwo q` 这类会不断改变候选集的序列）

## 2. 为什么偏偏是这个配置组合

`usesWindowGlass` 的成立条件是 `liquid_enable && glass_window && macOS ≥ 27`（见 `SquirrelApplicationDelegate.applicationWillFinishLaunching`）。代码里有多处几何逻辑**只在这个标志为真时才执行**，其中就包括后来查明的主要肇因——宽度量化器：

```swift
if usesWindowGlass && theme.memorizeSize && !vertical && !showingStatus {
    let widthQuantum: CGFloat = 20
    let quantizedWidth = (contentRect.width / widthQuantum).rounded(.up) * widthQuantum
    ...
}
```

这解释了配置相关性。而上下方的差异则源于 Cocoa 的窗口锚定方式（见 3.2）。

## 3. 根因

抖动不是单一原因，而是**四层问题叠加**。按对观感的影响排序：

### 3.1 宽度：无记忆量化器 + 内容宽度按字数跳变（主因）

面板宽度跟随最长候选词。连续按键时 Rime 返回的候选集不断变化，**最长候选的字数在 1~4 字之间跳动**。实测 `contentRect.width` 序列：

```
49.7891   65.7891   81.7891   97.7891      步长恰好 16.0
66.8451   82.8451   98.8451               步长恰好 16.0
```

`16.0` 正是 `font_point: 16` 下一个汉字的宽度。同一次组字内实测到的摆幅：

```
11:15:57.182  contentW= 65.7891  → panelW= 88
11:15:57.386  contentW=131.6328  → panelW=154
11:15:57.536  contentW= 49.7891  → panelW= 72
11:15:57.646  contentW= 65.7891  → panelW= 88
```

464ms 内窗口宽度 88 → 154 → 72 → 88。

原有的 `ceil(w / 20) * 20` 量化器不但没能抑制，反而**放大**了抖动：它是无记忆的，当自然宽度在 20 的倍数附近徘徊时，几个 point 的内容变化会被放大成 20pt 乃至 40pt 的窗口跳变，并在连续按键之间来回横跳。

### 3.2 上下方摆放的不对称

Cocoa 按**左下角**定位窗口。面板在光标下方时需要保持顶边不动，于是：

```swift
panelRect.origin.y = topEdge - panelRect.height   // origin 必须吸收每一次高度变化
```

而在光标上方时底边是锚点，`origin.y = position.maxY + offsetHeight` 与高度无关。这就是「下方抖、上方正常」的来源——**下方摆放会把任何高度变化转换成窗口位移**。

### 3.3 窗口 frame 动画放大了竞态

原先对可见玻璃面板的 frame 变化做了 0.12s 的 morph 动画，本意是用连续运动掩盖窗口服务器合成与 app 内容提交之间的一次错拍。

实际效果相反。窗口几何由窗口服务器拥有，`animator().setFrame` 只能在主线程逐帧重推；每一步都会 resize content view 并 autoresize 内层视图，而这些几何变更在另一个 CA 提交里落地。在光标下方（origin 随高度变化）时，内容在整个动画期间都在追赶面板边缘。**它把一次错拍摊成了持续 0.12s 的滞后。**

### 3.4 亚像素几何与宿主上报的光标矩形抖动

两个独立的次级来源：

- **面板尺寸吸附了像素网格，原点没有。** `origin.y = position.minY - offsetHeight - height`，而 `position` 来自客户端且通常是分数值。窗口服务器独立取整 origin 与 backing store 尺寸，两者反向进位时顶边整体位移 1 个设备像素。
- **宿主上报的光标矩形本身在抖。** `SquirrelInputController.showPanel` 在 `client.setMarkedText(...)` **之后 1ms** 就调用 `client.attributes(forCharacterIndex:lineHeightRectangle:)`，许多 App 此时返回的还是上一帧布局。实测：

  ```
  caretY 802.0000 ↔ 803.0000      caretH 21.0000 ↔ 22.0000
  caretH 18.2000 ↔ 19.0000
  ```

  个别情况下甚至返回全零矩形，导致面板瞬移到屏幕左下角 `(0, 5)`。

### 3.5 候选高亮变化的完整显示链路（当前重点）

候选词的“过滤”并不发生在 Squirrel UI 层。Rime 在 `SquirrelInputController.rimeUpdate()` 中提供当前页的候选集合和高亮索引：

```swift
ctx.menu.num_candidates
ctx.menu.candidates[i].text
ctx.menu.candidates[i].comment
ctx.menu.highlighted_candidate_index
```

Squirrel 只把这些值复制成 `candidates`、`comments`、`labels`，再传给 `SquirrelPanel.update()`。因此候选数量、候选内容和逻辑高亮索引的变化，主要由 Rime 的候选生成和分页决定；UI 端负责排序、排版和绘制。

UI 端的流程是：

1. `SquirrelPanel.update(update: true)` 保存候选数组和逻辑高亮索引。
2. `renderCurrentText()` 根据 `candidateOrderReversed` 构造显示顺序。逻辑索引仍对应 Rime，显示索引可能是反向的。
3. 当前高亮候选使用 `highlightedAttrs`、`labelHighlightedAttrs` 和 `commentHighlightedAttrs`；其他候选使用普通属性。
4. 每个候选在整段 `NSMutableAttributedString` 中生成一个 `candidateRange`。
5. `SquirrelView.draw()` 遍历这些 range：高亮候选单独生成 `highlightedPath`，其余候选合并成 `candidatePaths`。
6. 每次绘制都会执行 `panelLayer.sublayers = nil`，然后重新创建候选背景、高亮背景、阴影和 mask 层。

因此高亮从候选 `i` 变为候选 `j` 时，并不是只修改一个颜色属性，而是同时发生：

```text
旧高亮文本属性恢复
新高亮文本属性应用
TextKit 文本内容重新布局
candidateRanges 重新生成
旧高亮从 candidatePaths 移回
新高亮从 candidatePaths 移出
highlightedPath 和阴影层重新创建
panelLayer 的整个 sublayer 树被清空并重建
```

高亮属性当前只改变颜色，字体和 baselineOffset 相同，所以单纯的高亮切换理论上不应改变文字度量。不过它仍然会改变 layer 树和离屏文字图像的提交时序，这与窗口级 Liquid Glass 的合成可能发生在同一个输入事件中。

还有一个容易被忽略的二次重建路径。`show()` 为了判断面板最终位于光标上方还是下方，会进行最多两次布局计算。如果第一次计算得出的 `panelIsAboveCaret` 改变了 `candidateOrderReversed`，它会在 `show()` 内再次调用 `renderCurrentText()`，于是一次输入更新会经历两次候选排序、TextKit 布局和高亮路径生成：

```swift
if wantsReversedCandidates != candidateOrderReversed && layoutPass == 0 {
    candidateOrderReversed = wantsReversedCandidates
    renderCurrentText(highlighted: cursorIndex, theme: theme)
    continue
}
```

如果面板恰好在光标上下边界之间切换，这条路径会让候选顺序、高亮位置和面板几何在一次更新中互相影响。它是目前“高亮变化造成抖动”假设中最值得优先验证的代码路径。

需要区分两种现象：

- Rime 返回了不同数量或不同长度的候选。这会改变 `contentRect`，从而可能改变 panel 高度或宽度。
- 候选集合不变，只是 `highlighted_candidate_index` 改变。这时 panel 尺寸理论上应保持不变；如果仍抖动，重点应检查 `panelLayer.sublayers` 的整树重建和 `show()` 内的二次 `renderCurrentText()`。

## 4. 修复

### 4.1 宽度改为单调高水位（`SquirrelPanel.show()`）

```swift
if usesWindowGlass && theme.memorizeSize && !vertical && !showingStatus {
    if let previous = widthSnapshot, contentRect.width < previous {
        contentRect.size.width = previous          // 一次组字内只涨不跌
    }
    stablePanelWidth = contentRect.width
    naturalPanelSize.width = contentRect.width + edgeInset.width * 2 + theme.pagingOffset
}
```

面对几十 point 的摆幅，任何量化桶或死区都无能为力，只有高水位能彻底消除。这与竖排布局早已在用的 `maxHeight` 是同一套语义，也正是 `memorize_size` 这个选项名字的含义（`data/squirrel.yaml` 中描述为 "reduce jumping"）。高水位在 `hide()` 时随其他粘滞状态一起重置，即**每次组字重新开始**。

代价：组字后期面板会保持在本次最宽候选的宽度，不再回缩。这是 `memorize_size` 的既定取舍。

### 4.2 移除所有面板动画（commit `0c3c779`）

删除两处动画及其全部支撑代码：

- 0.12s 窗口 frame morph，以及只为它存在的 `.minYMargin` 预偏移补偿
- 0.14s/0.1s 出现消失缩放淡入淡出，以及 `VisibilityState` 状态机、`visibilityAnimationID`、四处 reduce-motion 判断

`frameChanged` 现在只有一条 `duration = 0` + `allowsImplicitAnimation = false` 的即时 `setFrame` 路径。

保留的是**抑制**动画的机制：`animationBehavior = .none`、`CATransaction.setDisableActions(true)`、`layerContentsPlacement` 锚定，以及 `runAnimationGroup` 外壳（Apple 文档指定的 `NSDisableScreenUpdates` 替代品，用于原子性，duration 为 0）。

### 4.3 几何对齐到设备像素网格（commit `aa472fd`）

```swift
func backingAligned(_ value: CGFloat, rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> CGFloat {
    let scale = max(screenScale, 1)
    return (value * scale).rounded(rule) / scale
}
```

- 宽高两轴都吸附到网格
- **把朝向光标的那条边钉在网格上，再由它反推 origin**：

  ```swift
  let topEdge = backingAligned(position.minY - SquirrelTheme.offsetHeight)
  panelRect.origin = NSPoint(x: ..., y: topEdge - panelRect.height)
  ```

  因为网格对齐的偏移量与取整运算可交换（`backingAligned(C - h) ≡ backingAligned(C) - h`，当 `h` 在网格上），顶边跨任意高度变化都逐像素不变。
- 缩放系数取**面板实际所在屏幕**的 `backingScaleFactor`（`currentScreen()` 中的 `screenScale`），而非窗口的，以兼容混合 DPI 多屏。

### 4.4 光标矩形粘滞与退化保护（`stabilizedPosition()`）

```swift
let degenerate = raw.height <= 0 && raw.width <= 0 && raw.origin == .zero
if degenerate { return previous }                    // 全零矩形：沿用上次

let tolerance = min(max(raw.height * 0.5, 1), 8)     // 半个光标行高，钳在 1~8pt
if abs(raw.minY - previous.minY) < tolerance { settled.origin.y = previous.origin.y }
if abs(raw.height - previous.height) < tolerance { settled.size.height = previous.size.height }
```

方向上做了区分：**x 与 width 始终跟随客户端**（打字时光标本就右移，属正确行为），**只有垂直方向被保持**，因为只有它会被摆放逻辑转换成窗口原点。真正换行时变化是一整行高度，必然突破容差。

效果（实测）：整段组字过程中面板顶边完全钉死。

| 会话 | `panel.y + panel.h` | 顶边 |
|---|---|---|
| caretY=802 | 611+186 / 640+157 / 756+41 | 全部 = 797 |
| caretY=203 | 12+186 / 70+128 / 157+41 | 全部 = 198 |

### 4.5 高度粘滞（防御性，当前为 no-op）

```swift
if !vertical && !showingStatus {
    let rowHeight = candidateRowHeight(for: theme)
    if let previous = heightSnapshot, abs(naturalPanelSize.height - previous) < rowHeight / 2 {
        naturalPanelSize.height = previous
    }
    stablePanelHeight = naturalPanelSize.height
}
```

阈值为半行。实测中高度**严格按行量化、零漂移**（19 / 106 / 135 / 164，步长恒为 29.0000），因此这段目前从未触发。保留作为防御——换字体方案、中英混排或带 emoji 注释时仍可能出现分数行高。

### 4.6 文字面纳入同一次提交

自定义 TextKit 2 文字管线（`SquirrelView` 的 `textImageLayer`）另有三处问题：

- **`commitTextRendering()` 原本在 `NSAnimationContext.endGrouping()` 之后调用**，即在 `setFrame(display: true)` 所开的 AppKit geometry/drawing 栅栏**之外**。底板由 `draw(_:)` 在栅栏内更新，文字却晚一次提交，导致每次按键有一帧文字滞后于面板。现已移到 `view.frame` 定稿之后、`beginGrouping()` 之前。
- **位图翻转锚错了对象**：位图行数是 `ceil(h·s)`，翻转却锚在视图高度 `h` 上，差出 `δ = ceil(h·s) − h·s ∈ [0,1)` 个设备像素；而 `contentsGravity = .topLeft` 把图像顶边钉在图层顶边，这个 δ 就成了随面板高度变化的可见下移量。现改为 `context.translateBy(x: 0, y: CGFloat(height) / scale)`，锚在位图自身高度上。
- **两处缩放来源不一致**：渲染用 `window?.backingScaleFactor`，几何对齐用 `screenScale`。现统一为由 panel 传入 `commitTextRendering(backingScale:)`。

### 4.7 统一首行、中间行和末行的高亮高度

`SquirrelView.drawPath()` 原先会对堆叠候选中的首行和末行额外加入 `edgeInset` 或
`hilitedCornerRadius`。因此同一个高亮背景在中间行和边缘行使用了不同的矩形高度；当高亮索引从中间移动到第一行或最后一行时，背景会出现可见的高度跳变。

之前移除显式的首行、末行扩展后，问题仍然存在。真正的第二层来源是后续的
`expand(vertex:innerBorder:outerBorder:)`：它把超出 `innerBox` 的点映射到 `outerBox`。
首行顶部和末行底部本来就会碰到 `innerBox` 的边界，因此分别被映射到面板外框的上、下边缘，
重新产生了“首行上方填充、末行下方填充”。

当前堆叠布局改用 `expandStacked`：只保留水平方向的边缘处理，垂直方向不再根据
`innerBox` 扩展，只在高亮实际越出候选区域时裁剪到 `outerBox`。这样 `contentRect + linespace`
计算出的行高不会因为行位于首尾而改变，同时仍保留高亮候选的水平内缩和面板外框圆角。

### 4.8 面板圆角与内容边距解耦

旧算法用 `border_height + corner_radius` 和 `border_width + corner_radius` 生成
`edgeInset`，再同时用于窗口尺寸和 `NSTextView.textContainerInset`。因此
`corner_radius: 30` 会让水平面板上下各增加约 29 pt。

现在新增 `content_horizontal_inset` 与 `content_vertical_inset`。`edgeInset` 只由这两个
内容边距决定；`corner_radius` 只用于面板外框/Glass，`hilited_corner_radius` 只用于高亮路径。
旧的段落和预编辑几何也改用内容边距，不再因高亮圆角变化而扩大文字区域。

### 4.9 高亮候选使用真实圆角路径

候选高亮原先统一使用 `drawSmoothLines` 生成贝塞尔路径，并把
`hilited_corner_radius` 直接换算为 `alpha = 0.3r`、`beta = 1.4r`。这不是圆的
标准三次贝塞尔近似；当行高小于两倍半径时，控制点还会互相越过，导致首行/末行
看起来像被填充，或圆角被裁剪成不规则形状。

现在单行候选（包括 `stacked` 模式）直接使用
`CGPath(roundedRect:cornerWidth:cornerHeight:)`，并把半径限制为实际高亮矩形短边的
一半。线性多行候选仍保留分段路径，但使用四分之一圆的控制系数 `0.55228475r`，
同时按每个实际分段矩形限制半径。这样 `corner_radius` 只影响面板外框，
`hilited_corner_radius` 只影响候选高亮几何，不再通过过大的控制点改变行高或形状。

## 5. 已排除的假设

记录在此，避免重复排查。

| 假设 | 结论 | 证据 |
|---|---|---|
| 高亮候选变化改变了文本度量 | **否** | `attrs` 与 `highlightedAttrs` 只差 `.foregroundColor`，`.font` 与 `.baselineOffset`完全相同（`SquirrelTheme.swift`）。度量相同 ⇒ `headIndent`、换行、`contentRect` 全部相同 |
| 高亮变化完全不会影响合成 | **未证实** | 字体度量相同，但每次高亮都会替换整段 attributed string，并清空、重建 `panelLayer.sublayers`；这仍可能在窗口 Glass 提交期间造成视觉抖动 |
| UI 层过滤了候选 | **否** | 候选数量、文本、注释和逻辑高亮索引来自 Rime 的 `ctx.menu`；Squirrel 只负责显示顺序、属性和几何 |
| 候选顺序永远稳定 | **否** | `show()` 会根据最终面板位置修改 `candidateOrderReversed`，并在第一次布局后再次调用 `renderCurrentText()` |
| 鼠标悬停改高亮触发重入渲染 | **否**（但另有 bug） | `sources/` 下没有任何 `NSTrackingArea`，`.mouseEntered` 永不触发，`acceptsMouseMovedEvents` 恒为 `false`，`.mouseMoved` 永不送达。**这意味着鼠标悬停高亮功能本身是坏的**，是一个独立待修问题 |
| 每次按键触发多次渲染 | **否** | `showPanel` 全局只有一个调用点（`SquirrelInputController.swift`），日志显示每次按键只有一条几何记录 |
| 高度因字体回退产生亚点级漂移 | **否** | 实测行距恒为 29.0000，`contentH` 全程整数 |
| 文字管线内部（字形绘制）导致抖动 | **否** | `debug_freeze_panel_frame: true` 时抖动消失 ⇒ 由 frame 变化驱动 |

## 6. 诊断方法

### 6.1 诊断开关

`squirrel.yaml` 的 `style:` 段（均为诊断用途，默认关闭）：

| 开关 | 作用 |
|---|---|
| `debug_content_mode` | `all` / `blank` / `panel` / `text` / `text_clear`，分离显示面板底板与文字图层 |
| `debug_freeze_panel_frame` | 冻结首个窗口 frame，内容继续更新——用于判断抖动是否由几何驱动 |
| `debug_log_geometry` | 输出每次面板更新的几何日志 |
| `debug_skip_text_scroll` | 跳过 TextKit 布局后的滚动复位 |
| `prefer_panel_above_cursor` | 强制横排面板置于光标上方（底边锚定，origin 恒定） |

> ⚠️ 注意 `debug_content_mode: text_clear` 当前会让 `hidePanel` 与 `hideText` 同时为真（见 `SquirrelView.setTextDebugVisibility`），叠加前景色置空后是三重隐藏，实际什么都不显示。这与注释描述的意图不符，是个待修的开关逻辑问题。

### 6.2 读取几何日志

日志经 `os_log` 输出（`NSLog` 会被统一日志脱敏成 `<private>`，不可用）：

```sh
log show --predicate 'subsystem == "im.rime.inputmethod.Squirrel"' --last 10m --style compact
```

单行格式：

```
rows=6 above=0 changed=1
 | contentW=65.7891 rawPanelW=87.7891 -> panelW=88.0000
 | contentH=164.0000 rawPanelH=186.0000 -> panelH=186.0000
 | caretY 802.0000 -> 802.0000 caretH 22.0000 -> 22.0000 caretX=431.0000
 | panel=(431.0000, 611.0000, 88.0000, 186.0000) scale=2.00
```

判读要点：

- `changed` — 本次是否真的调用了 `setFrame`。修复到位后同一次组字内应大量为 `0`
- `rawPanelW -> panelW` / `rawPanelH -> panelH` — 两值不等说明高水位／粘滞正在起作用
- `caretY A -> B` — 两值不等说明宿主上报的光标矩形在抖，已被吸收
- `panel.y + panel.h` — 光标下方摆放时这个和应当恒定（即顶边不动）
- `rows` — 若行数本身在逐键变化，属 Rime 侧候选数量变化，非 UI 层问题

### 6.3 分层定位流程

```
抖动
 ├─ debug_freeze_panel_frame: true 后消失？
 │   ├─ 是 → 几何驱动，看日志的 contentW / contentH / caretY 哪一列在动
 │   └─ 否 → 文字管线内部，检查 commitTextRendering 的提交时机与位图坐标
 └─ debug_content_mode: panel 稳、text 抖？
     └─ 注意这不一定说明文字管线有问题：底板是一大块均匀圆角矩形，
        平移 1px 几乎不可见；文字是高频细节，同样的位移极其刺眼
```

## 7. 遗留事项

1. **鼠标悬停高亮功能失效** —— 缺 `NSTrackingArea`（见第 5 节）
2. **`text_clear` 开关逻辑错误** —— `hideText` 不应包含 `.textClear`
3. **高水位仍受 `usesWindowGlass` 门控** —— 关闭玻璃时横排宽度依然裸跟随内容。是否放开门控待定
4. **翻转滞回未实现** —— 屏幕底部输入时，若面板高度恰在「放得下／放不下」阈值附近，会逐键在光标上下翻转。当前未加滞回，属预防性改进
5. **诊断代码待清理** —— 确认稳定后可移除 `debug_log_geometry`、`geometryLog` 及 `rawContentWidth` 等临时变量

## 8. 当前总结

目前可以把问题拆成两个层面：

1. 候选集合变化会改变文字长度、候选行数和 panel 几何，这是正常的布局变化；
2. 高亮索引变化会触发整段文本重建和整棵候选背景 layer 树重建，即使 panel 几何没有变化，也可能造成 Glass 合成抖动。

现有证据已经排除了 `NSTextView` 的独立显示层作为唯一原因。下一步应做一个只改变高亮、不改变候选字符串和候选数量的测试，并记录 `debug_log_geometry`：

- 如果 `frameChanged=0` 但仍抖动，根因在高亮文本/候选 layer 的提交方式；
- 如果 `frameChanged=1`，说明高亮切换间接改变了排序、TextKit range 或 panel 几何；
- 如果 `above` 在相邻更新之间变化，优先修复 `show()` 的候选反转二次重建；
- 如果 `above` 不变但抖动仍存在，优先把高亮背景改成持久的单独 layer，只更新 `path`、`fillColor` 和 `shadowPath`，不要清空 `panelLayer.sublayers`。

最可能的修复方向是让候选集合、文本布局和 panel frame 在一次更新中确定，再单独更新高亮 layer。高亮切换不应重新生成整段 attributed string，也不应重建所有候选背景层。
