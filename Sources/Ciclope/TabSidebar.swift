import AppKit

// Barra lateral izquierda de pestañas: nombre (editable con doble click) +
// resumen del último comando. Click cambia, arrastrar reordena, soltar fuera
// de la sidebar recoloca o desancla.
//
// Importante: las celdas se actualizan EN SITIO cuando no cambia el número de
// pestañas; reconstruirlas en cada refresco mataba los clicks a medias.
final class TabSidebarView: NSView {
    struct Item {
        let name: String
        let subtitle: String
    }

    struct ArchivedItem {
        let id: String
        let name: String
        let subtitle: String
    }

    var onSelect: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onDropBeyond: ((Int, NSPoint) -> Void)?   // soltada fuera de la sidebar
    var onDragMoved: ((NSPoint) -> Void)?         // arrastre en vivo (para el hint)
    var onRename: ((Int, String) -> Void)?
    var onToggleArchive: (() -> Void)?            // click en la barra del archivo
    var onArchiveTab: ((Int) -> Void)?            // pestaña soltada sobre el archivo
    var onRestoreArchived: ((String) -> Void)?    // click en una sesión archivada
    var onDeleteArchived: ((String) -> Void)?     // ✕ de una sesión archivada

    private var cells: [TabCell] = []
    private let cellHeight: CGFloat = 46

    // sección de archivo, anclada abajo: barra siempre visible (es el drop
    // target) y, desplegada, las sesiones congeladas encima de ella
    private var archiveBar: ArchiveBarCell?
    private var archivedCells: [ArchivedCell] = []
    private var archivedIDs: [String] = []
    private var archiveExpanded = false
    private let archiveBarHeight: CGFloat = 24
    private let archivedCellHeight: CGFloat = 36

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.chromeBg.cgColor
        layer?.borderColor = Theme.accent.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 5
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        layer?.backgroundColor = Theme.chromeBg.cgColor
        layer?.borderColor = Theme.accent.withAlphaComponent(0.18).cgColor
        archiveBar?.applyTheme()
        archivedCells.forEach { $0.applyTheme() }
    }

    func update(items: [Item], active: Int, archived: [ArchivedItem], archiveExpanded expanded: Bool) {
        // no tocar nada mientras se edita un nombre
        if cells.contains(where: { $0.isEditing }) { return }

        // mismo número de pestañas: refrescar textos y estilo sin reconstruir
        if cells.count == items.count {
            for (i, cell) in cells.enumerated() {
                cell.apply(item: items[i], active: i == active)
            }
        } else {
            cells.forEach { $0.removeFromSuperview() }
            cells = []
            for (i, item) in items.enumerated() {
                let cell = TabCell(index: i, item: item, active: i == active)
                cell.onClick = { [weak self] in self?.onSelect?(i) }
                cell.onClose = { [weak self] in self?.onCloseTab?(i) }
                cell.onRename = { [weak self] name in self?.onRename?(i, name) }
                cell.onDragMoved = { [weak self] screenPoint in self?.onDragMoved?(screenPoint) }
                cell.onDragEnded = { [weak self] screenPoint in
                    self?.handleDrop(from: i, screenPoint: screenPoint)
                }
                addSubview(cell)
                cells.append(cell)
            }
        }
        updateArchive(archived, expanded: expanded)
        layoutCells()
    }

    /// Refresca la sección de archivo; solo reconstruye las celdas si cambió
    /// la lista o el plegado (reconstruir en cada refresco mata los clicks).
    private func updateArchive(_ archived: [ArchivedItem], expanded: Bool) {
        if archiveBar == nil {
            let bar = ArchiveBarCell()
            bar.onClick = { [weak self] in self?.onToggleArchive?() }
            addSubview(bar)
            archiveBar = bar
        }
        archiveBar?.apply(count: archived.count, expanded: expanded)

        let ids = archived.map { $0.id }
        if ids != archivedIDs || expanded != archiveExpanded {
            archivedCells.forEach { $0.removeFromSuperview() }
            archivedCells = (expanded ? archived : []).map { item in
                let cell = ArchivedCell(item: item)
                cell.onRestore = { [weak self] in self?.onRestoreArchived?(item.id) }
                cell.onDelete = { [weak self] in self?.onDeleteArchived?(item.id) }
                addSubview(cell)
                return cell
            }
            archivedIDs = ids
            archiveExpanded = expanded
        }
    }

    override func layout() {
        super.layout()
        layoutCells()
    }

    private func layoutCells() {
        for (i, cell) in cells.enumerated() {
            cell.frame = NSRect(x: 3, y: bounds.height - CGFloat(i + 1) * cellHeight - 4,
                                width: bounds.width - 6, height: cellHeight - 4)
        }
        archiveBar?.frame = NSRect(x: 3, y: 4, width: bounds.width - 6, height: archiveBarHeight)
        // desplegado: las archivadas crecen desde la barra hacia arriba,
        // la primera de la lista queda arriba del todo
        for (i, cell) in archivedCells.enumerated() {
            let fromBottom = archivedCells.count - 1 - i
            cell.frame = NSRect(x: 3, y: 8 + archiveBarHeight + CGFloat(fromBottom) * archivedCellHeight,
                                width: bounds.width - 6, height: archivedCellHeight - 3)
        }
    }

    private func handleDrop(from: Int, screenPoint: NSPoint) {
        guard let window else { return }
        if window.frame.contains(screenPoint) {
            let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            // sobre la barra del archivo (con margen): congelar la pestaña
            if let bar = archiveBar, bar.frame.insetBy(dx: 0, dy: -10).contains(local) {
                onArchiveTab?(from)
                return
            }
            if bounds.insetBy(dx: -20, dy: -20).contains(local) {
                // dentro de la sidebar: reordenar
                let target = max(0, min(cells.count - 1, Int((bounds.height - local.y - 4) / cellHeight)))
                if target != from { onMove?(from, target) }
                return
            }
        }
        // fuera de la sidebar: el controlador decide (división central, docks o ventana)
        onDropBeyond?(from, screenPoint)
    }
}

private final class TabCell: NSView, NSTextFieldDelegate {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    private(set) var isEditing = false

    private var dragging = false
    private var downPoint: NSPoint = .zero
    private var active: Bool

    private let bar = NSView()
    private let num = NSTextField(labelWithString: "")
    private let nameField = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")

    init(index: Int, item: TabSidebarView.Item, active: Bool) {
        self.active = active
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4

        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        num.stringValue = "\(index + 1)"
        num.font = Theme.font(size: 9)
        num.translatesAutoresizingMaskIntoConstraints = false
        addSubview(num)

        nameField.font = Theme.font(size: 11)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameField)

        sub.font = Theme.font(size: 9)
        sub.lineBreakMode = .byTruncatingTail
        sub.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sub)

        let close = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.font = NSFont.systemFont(ofSize: 9)
        close.contentTintColor = Theme.dimFg.withAlphaComponent(0.7)
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 2),
            bar.heightAnchor.constraint(equalTo: heightAnchor, constant: -12),
            num.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            num.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            nameField.leadingAnchor.constraint(equalTo: num.trailingAnchor, constant: 6),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -4),
            sub.leadingAnchor.constraint(equalTo: num.trailingAnchor, constant: 6),
            sub.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])

        apply(item: item, active: active)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Refresca contenido y estilo sin reconstruir la celda (los clicks sobreviven).
    func apply(item: TabSidebarView.Item, active: Bool) {
        self.active = active
        if !isEditing { nameField.stringValue = item.name }
        sub.stringValue = item.subtitle
        layer?.backgroundColor = active ? Theme.accent.withAlphaComponent(0.10).cgColor : NSColor.clear.cgColor
        bar.layer?.backgroundColor = active ? Theme.accent.cgColor : NSColor.clear.cgColor
        num.textColor = active ? Theme.accent : Theme.dimFg.withAlphaComponent(0.6)
        nameField.textColor = active ? Theme.fg : Theme.dimFg
        sub.textColor = Theme.dimFg.withAlphaComponent(active ? 0.9 : 0.55)
    }

    @objc private func closeTapped() { onClose?() }

    // MARK: - Renombrar (doble click)

    private func beginEditing() {
        isEditing = true
        nameField.isEditable = true
        nameField.isBordered = true
        nameField.drawsBackground = true
        nameField.backgroundColor = NSColor.black
        nameField.textColor = Theme.fg
        window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditing else { return }
        isEditing = false
        nameField.isEditable = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        onRename?(nameField.stringValue.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Ratón (umbral de 5px para distinguir click de arrastre)

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            beginEditing()
            return
        }
        dragging = false
        downPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isEditing else { return }
        let p = event.locationInWindow
        if !dragging && hypot(p.x - downPoint.x, p.y - downPoint.y) < 5 { return }
        dragging = true
        alphaValue = 0.5
        onDragMoved?(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        guard !isEditing else { return }
        if dragging {
            onDragEnded?(NSEvent.mouseLocation)
        } else if event.clickCount == 1 {
            onClick?()
        }
        dragging = false
    }
}

// Barra del archivo, abajo del todo de la sidebar: muestra el contador, hace
// de drop target para congelar pestañas y con un click despliega/pliega.
private final class ArchiveBarCell: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        toolTip = L.t("archive.tip")
        label.font = Theme.font(size: 10)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(count: Int, expanded: Bool) {
        let chevron = expanded ? "▾" : "▸"
        label.stringValue = "\(chevron) 🗃 \(L.t("archive.title"))" + (count > 0 ? " (\(count))" : "")
        label.textColor = count > 0 ? Theme.dimFg : Theme.dimFg.withAlphaComponent(0.5)
    }

    func applyTheme() {
        layer?.backgroundColor = Theme.accent.withAlphaComponent(0.06).cgColor
        layer?.borderColor = Theme.accent.withAlphaComponent(0.25).cgColor
        layer?.borderWidth = 1
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// Una sesión congelada en el archivo: click restaura, ✕ la borra del archivo.
private final class ArchivedCell: NSView {
    var onRestore: (() -> Void)?
    var onDelete: (() -> Void)?
    private let nameLabel = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")

    init(item: TabSidebarView.ArchivedItem) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        toolTip = L.t("archive.cell.tip")

        nameLabel.stringValue = "👻 " + item.name
        nameLabel.font = Theme.font(size: 10)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        sub.stringValue = item.subtitle
        sub.font = Theme.font(size: 8)
        sub.lineBreakMode = .byTruncatingTail
        sub.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sub)

        let close = NSButton(title: "✕", target: self, action: #selector(deleteTapped))
        close.isBordered = false
        close.font = NSFont.systemFont(ofSize: 9)
        close.contentTintColor = Theme.dimFg.withAlphaComponent(0.7)
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -4),
            sub.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            sub.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        layer?.backgroundColor = Theme.chromeBg.cgColor
        layer?.borderColor = Theme.accent.withAlphaComponent(0.15).cgColor
        layer?.borderWidth = 1
        nameLabel.textColor = Theme.dimFg
        sub.textColor = Theme.dimFg.withAlphaComponent(0.55)
    }

    @objc private func deleteTapped() { onDelete?() }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 1, bounds.contains(convert(event.locationInWindow, from: nil)) {
            onRestore?()
        }
    }
}
