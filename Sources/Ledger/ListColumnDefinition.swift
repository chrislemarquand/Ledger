import AppKit

struct ListColumnDefinition {
    let id: String
    let label: String
    let defaultWidth: CGFloat
    let minWidth: CGFloat
    let defaultIsVisible: Bool
    let isSortable: Bool

    // MARK: - Built-in column IDs

    static let idName        = "name"
    static let idCreated     = "created"
    static let idModified    = "modified"
    static let idSize        = "size"
    static let idKind        = "kind"

    // MARK: - Metadata column IDs

    static let idRating      = "col-rating"
    static let idMake        = "col-make"
    static let idModel       = "col-model"
    static let idLens        = "col-lens"
    static let idAperture    = "col-aperture"
    static let idShutter     = "col-shutter"
    static let idISO         = "col-iso"
    static let idFocal       = "col-focal"
    static let idDateTaken   = "col-date-taken"
    static let idDimensions  = "col-dimensions"
    static let idTitle       = "col-title"
    static let idDescription = "col-description"
    static let idKeywords    = "col-keywords"
    static let idCopyright   = "col-copyright"
    static let idCreator     = "col-creator"

    // MARK: - Column sets

    static let builtIn: [ListColumnDefinition] = [
        .init(id: idName,     label: "Name",          defaultWidth: 300, minWidth: 60, defaultIsVisible: true,  isSortable: true),
        .init(id: idCreated,  label: "Date Created",  defaultWidth: 160, minWidth: 84, defaultIsVisible: true,  isSortable: true),
        .init(id: idModified, label: "Date Modified", defaultWidth: 160, minWidth: 84, defaultIsVisible: false, isSortable: true),
        .init(id: idSize,     label: "Size",          defaultWidth: 90,  minWidth: 64, defaultIsVisible: true,  isSortable: true),
        .init(id: idKind,     label: "Kind",          defaultWidth: 120, minWidth: 84, defaultIsVisible: true,  isSortable: true),
    ]

    static let metadata: [ListColumnDefinition] = [
        .init(id: idRating,      label: "Rating",        defaultWidth: 60,  minWidth: 50, defaultIsVisible: false, isSortable: false),
        .init(id: idMake,        label: "Camera Make",   defaultWidth: 120, minWidth: 60, defaultIsVisible: false, isSortable: false),
        .init(id: idModel,       label: "Camera Model",  defaultWidth: 140, minWidth: 60, defaultIsVisible: false, isSortable: false),
        .init(id: idLens,        label: "Lens",          defaultWidth: 160, minWidth: 80, defaultIsVisible: false, isSortable: false),
        .init(id: idAperture,    label: "Aperture",      defaultWidth: 80,  minWidth: 60, defaultIsVisible: false, isSortable: false),
        .init(id: idShutter,     label: "Shutter Speed", defaultWidth: 90,  minWidth: 70, defaultIsVisible: false, isSortable: false),
        .init(id: idISO,         label: "ISO",           defaultWidth: 60,  minWidth: 50, defaultIsVisible: false, isSortable: false),
        .init(id: idFocal,       label: "Focal Length",  defaultWidth: 90,  minWidth: 70, defaultIsVisible: false, isSortable: false),
        .init(id: idDateTaken,   label: "Date Taken",    defaultWidth: 160, minWidth: 84, defaultIsVisible: false, isSortable: false),
        .init(id: idDimensions,  label: "Dimensions",    defaultWidth: 90,  minWidth: 70, defaultIsVisible: false, isSortable: false),
        .init(id: idTitle,       label: "Title",         defaultWidth: 160, minWidth: 80, defaultIsVisible: false, isSortable: false),
        .init(id: idDescription, label: "Description",   defaultWidth: 200, minWidth: 80, defaultIsVisible: false, isSortable: false),
        .init(id: idKeywords,    label: "Keywords",      defaultWidth: 160, minWidth: 80, defaultIsVisible: false, isSortable: false),
        .init(id: idCopyright,   label: "Copyright",     defaultWidth: 160, minWidth: 80, defaultIsVisible: false, isSortable: false),
        .init(id: idCreator,     label: "Creator",       defaultWidth: 120, minWidth: 60, defaultIsVisible: false, isSortable: false),
    ]

    static var all: [ListColumnDefinition] { builtIn + metadata }

    /// All columns except Name, which is always visible and not user-toggleable.
    static var toggleable: [ListColumnDefinition] { all.filter { $0.id != idName } }
}
