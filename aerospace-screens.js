// NSScreen.screens and AeroSpace's AppKit index have the same ordering.
ObjC.import('AppKit')
ObjC.import('CoreGraphics')

function run() {
    const screens = $.NSScreen.screens
    const result = []
    for (let i = 0; i < Number(screens.count); i++) {
        const screen = screens.objectAtIndex(i)
        const id = Number(ObjC.unwrap(screen.deviceDescription.objectForKey('NSScreenNumber')))
        const rect = $.CGDisplayBounds(id)
        result.push({
            name: ObjC.unwrap(screen.localizedName),
            x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height,
            builtin: Boolean($.CGDisplayIsBuiltin(id)), mirror: Number($.CGDisplayMirrorsDisplay(id)) !== 0
        })
    }
    return JSON.stringify(result)
}
