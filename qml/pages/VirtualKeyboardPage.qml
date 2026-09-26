pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root

    property alias inputText: inputArea.text
    property int keyboardMode: 0 // 0=ABC, 1=123, 2=#+=, 3=Arrows
    property bool shiftActive: false
    property bool capsLock: false
    property bool ctrlActive: false
    property bool altActive: false
    property bool autoCapitalization: true
    property string lastAction: "Ready"
    property bool calculatorResultReady: false
    property string calculationError: ""

    readonly property bool compact: width < 1250 || height < 760
    readonly property int pageMargin: compact ? 16 : 28
    readonly property int keyGap: compact ? 5 : 8
    // Doubled from the original 13/17 px after checking the real 1920x1200 panel.
    readonly property int keyFontSize: compact ? 26 : 34
    readonly property int pairedKeyFontSize: compact ? 24 : 32
    readonly property real conversionValue: currentNumericValue()
    readonly property string hexOutput: isFinite(conversionValue)
                                                ? formatBaseValue(conversionValue, 16, "0x", 8) : "—"
    readonly property string decimalOutput: isFinite(conversionValue)
                                                    ? formatCalculatorResult(conversionValue) : "—"
    readonly property string binaryOutput: isFinite(conversionValue)
                                                   ? formatBaseValue(conversionValue, 2, "0b", 16) : "—"

    readonly property var functionRow: [
        { label: "Esc", role: "escape" },
        { label: "F1", role: "function" }, { label: "F2", role: "function" },
        { label: "F3", role: "function" }, { label: "F4", role: "function" },
        { label: "F5", role: "function" }, { label: "F6", role: "function" },
        { label: "F7", role: "function" }, { label: "F8", role: "function" },
        { label: "F9", role: "function" }, { label: "F10", role: "function" },
        { label: "F11", role: "function" }, { label: "F12", role: "function" },
        { label: "ScrLk", role: "function" }, { label: "Pause", role: "function" }
    ]

    readonly property var alphaRows: [
        functionRow,
        [
            { top: "~", bottom: "`", value: "`", shifted: "~" },
            { top: "!", bottom: "1", value: "1", shifted: "!" },
            { top: "@", bottom: "2", value: "2", shifted: "@" },
            { top: "#", bottom: "3", value: "3", shifted: "#" },
            { top: "$", bottom: "4", value: "4", shifted: "$" },
            { top: "%", bottom: "5", value: "5", shifted: "%" },
            { top: "^", bottom: "6", value: "6", shifted: "^" },
            { top: "&", bottom: "7", value: "7", shifted: "&" },
            { top: "*", bottom: "8", value: "8", shifted: "*" },
            { top: "(", bottom: "9", value: "9", shifted: "(" },
            { top: ")", bottom: "0", value: "0", shifted: ")" },
            { top: "_", bottom: "-", value: "-", shifted: "_" },
            { top: "+", bottom: "=", value: "=", shifted: "+" },
            { label: "Backspace", role: "backspace", icon: "backspace", weight: 2.6 }
        ],
        [
            { label: "Tab", role: "tab", icon: "tab", weight: 1.55 },
            { label: "Q", value: "q", letter: true }, { label: "W", value: "w", letter: true },
            { label: "E", value: "e", letter: true }, { label: "R", value: "r", letter: true },
            { label: "T", value: "t", letter: true }, { label: "Y", value: "y", letter: true },
            { label: "U", value: "u", letter: true }, { label: "I", value: "i", letter: true },
            { label: "O", value: "o", letter: true }, { label: "P", value: "p", letter: true },
            { top: "{", bottom: "[", value: "[", shifted: "{" },
            { top: "}", bottom: "]", value: "]", shifted: "}" },
            { top: "|", bottom: "\\", value: "\\", shifted: "|" }
        ],
        [
            { label: "Caps Lock", role: "caps", icon: "caps", weight: 2.5 },
            { label: "A", value: "a", letter: true }, { label: "S", value: "s", letter: true },
            { label: "D", value: "d", letter: true }, { label: "F", value: "f", letter: true },
            { label: "G", value: "g", letter: true }, { label: "H", value: "h", letter: true },
            { label: "J", value: "j", letter: true }, { label: "K", value: "k", letter: true },
            { label: "L", value: "l", letter: true },
            { top: ":", bottom: ";", value: ";", shifted: ":" },
            { top: "\"", bottom: "'", value: "'", shifted: "\"" },
            { label: "Enter", role: "enter", icon: "enter", weight: 2.3 }
        ],
        [
            { label: "Shift", role: "shift", icon: "shift", weight: 2.25 },
            { label: "Z", value: "z", letter: true }, { label: "X", value: "x", letter: true },
            { label: "C", value: "c", letter: true }, { label: "V", value: "v", letter: true },
            { label: "B", value: "b", letter: true }, { label: "N", value: "n", letter: true },
            { label: "M", value: "m", letter: true },
            { top: "<", bottom: ",", value: ",", shifted: "<" },
            { top: ">", bottom: ".", value: ".", shifted: ">" },
            { top: "?", bottom: "/", value: "/", shifted: "?" },
            { label: "Shift", role: "shift", icon: "shift", weight: 2.25 }
        ],
        [
            { label: "Ctrl", role: "ctrl", weight: 1.45 },
            { label: "Alt", role: "alt", weight: 1.1 },
            { label: "Space", role: "space", weight: 6.1 },
            { label: "AltGr", role: "alt", weight: 1.1 },
            { label: "Ctrl", role: "ctrl", weight: 1.1 },
            { label: "", role: "left", icon: "left" },
            { label: "", role: "down", icon: "down" },
            { label: "", role: "up", icon: "up" },
            { label: "", role: "right", icon: "right" }
        ]
    ]

    readonly property var numberRows: [
        functionRow,
        [
            { label: "7", value: "7" }, { label: "8", value: "8" },
            { label: "9", value: "9" }, { label: "/", value: "/" },
            { label: "*", value: "*" },
            { label: "Backspace", role: "backspace", icon: "backspace", weight: 1.9 }
        ],
        [
            { label: "4", value: "4" }, { label: "5", value: "5" },
            { label: "6", value: "6" }, { label: "-", value: "-" },
            { label: "+", value: "+" },
            { label: "Delete", role: "delete", icon: "delete", weight: 1.9 }
        ],
        [
            { label: "1", value: "1" }, { label: "2", value: "2" },
            { label: "3", value: "3" }, { label: ".", value: "." },
            { label: "(", value: "(" },
            { label: "Enter =", role: "enter", icon: "enter", weight: 2.1 }
        ],
        [
            { label: "0", value: "0", weight: 2.1 },
            { label: "00", value: "00" }, { label: ")", value: ")" },
            { label: "Clear", role: "clear", weight: 1.4 },
            { label: "", role: "left", icon: "left" },
            { label: "", role: "right", icon: "right" }
        ]
    ]

    readonly property var symbolRows: [
        functionRow,
        [
            { label: "!", value: "!" }, { label: "@", value: "@" },
            { label: "#", value: "#" }, { label: "$", value: "$" },
            { label: "%", value: "%" }, { label: "^", value: "^" },
            { label: "&", value: "&" }, { label: "*", value: "*" },
            { label: "Backspace", role: "backspace", icon: "backspace", weight: 2.0 }
        ],
        [
            { label: "(", value: "(" }, { label: ")", value: ")" },
            { label: "[", value: "[" }, { label: "]", value: "]" },
            { label: "{", value: "{" }, { label: "}", value: "}" },
            { label: "<", value: "<" }, { label: ">", value: ">" },
            { label: "Delete", role: "delete", icon: "delete", weight: 2.0 }
        ],
        [
            { label: "+", value: "+" }, { label: "-", value: "-" },
            { label: "=", value: "=" }, { label: "_", value: "_" },
            { label: "\\", value: "\\" }, { label: "|", value: "|" },
            { label: "/", value: "/" }, { label: "?", value: "?" },
            { label: "Enter", role: "enter", icon: "enter", weight: 2.0 }
        ],
        [
            { label: "`", value: "`" }, { label: "~", value: "~" },
            { label: ";", value: ";" }, { label: ":", value: ":" },
            { label: "'", value: "'" }, { label: "\"", value: "\"" },
            { label: "Space", role: "space", weight: 3.0 },
            { label: "", role: "left", icon: "left" },
            { label: "", role: "right", icon: "right" }
        ]
    ]

    readonly property var arrowRows: [
        functionRow,
        [
            { label: "Home", role: "home", weight: 1.4 },
            { label: "", role: "up", icon: "up", weight: 2.0 },
            { label: "End", role: "end", weight: 1.4 }
        ],
        [
            { label: "", role: "left", icon: "left", weight: 2.0 },
            { label: "", role: "down", icon: "down", weight: 2.0 },
            { label: "", role: "right", icon: "right", weight: 2.0 }
        ],
        [
            { label: "Page Up", role: "pageup", weight: 1.4 },
            { label: "Select All", role: "selectall", weight: 1.8 },
            { label: "Page Down", role: "pagedown", weight: 1.4 }
        ],
        [
            { label: "Backspace", role: "backspace", icon: "backspace", weight: 1.75 },
            { label: "Space", role: "space", weight: 2.6 },
            { label: "Delete", role: "delete", icon: "delete", weight: 1.75 }
        ]
    ]

    readonly property var activeRows: keyboardMode === 0 ? alphaRows
                                          : keyboardMode === 1 ? numberRows
                                          : keyboardMode === 2 ? symbolRows
                                                               : arrowRows

    onKeyboardModeChanged: {
        calculatorResultReady = false
        calculationError = ""
    }

    gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop { position: 0.0; color: "#040a12" }
        GradientStop { position: 1.0; color: "#05080d" }
    }

    StackLayout.onIsCurrentItemChanged: {
        if (StackLayout.isCurrentItem)
            Qt.callLater(root.focusInput)
    }

    function hasSelection() {
        return inputArea.selectionStart !== inputArea.selectionEnd
    }

    function focusInput() {
        inputArea.forceActiveFocus()
    }

    function replaceSelection(value) {
        var start = Math.min(inputArea.selectionStart, inputArea.selectionEnd)
        var end = Math.max(inputArea.selectionStart, inputArea.selectionEnd)
        if (start !== end)
            inputArea.remove(start, end)
        var position = start !== end ? start : inputArea.cursorPosition
        inputArea.insert(position, value)
        inputArea.cursorPosition = position + value.length
        focusInput()
    }

    function shouldAutoCapitalize() {
        if (!autoCapitalization)
            return false
        var before = inputArea.text.slice(0, inputArea.cursorPosition)
        return /^\s*$/.test(before) || /(?:[.!?]\s+|\n\s*)$/.test(before)
    }

    function displayedLabel(keyData) {
        if (!keyData)
            return ""
        if (!keyData.letter)
            return keyData.label !== undefined ? keyData.label : (keyData.value || "")
        var uppercase = capsLock !== shiftActive
        if (!capsLock && !shiftActive && shouldAutoCapitalize())
            uppercase = true
        return uppercase ? keyData.value.toUpperCase() : keyData.value.toLowerCase()
    }

    function insertCharacter(keyData) {
        var value = keyData.value || ""

        // Calculator behavior: a digit after a completed result starts a new
        // calculation, while an operator continues from the displayed result.
        if (keyboardMode === 1 && calculatorResultReady) {
            if ("+-*/".indexOf(value) < 0)
                inputArea.clear()
            calculatorResultReady = false
        }
        calculationError = ""

        if (keyData.letter) {
            var uppercase = capsLock !== shiftActive
            if (!capsLock && !shiftActive && shouldAutoCapitalize())
                uppercase = true
            value = uppercase ? value.toUpperCase() : value.toLowerCase()
        } else if (shiftActive && keyData.shifted !== undefined) {
            value = keyData.shifted
        }

        if (ctrlActive) {
            var command = value.toLowerCase()
            if (command === "a") inputArea.selectAll()
            else if (command === "c") inputArea.copy()
            else if (command === "v") inputArea.paste()
            else if (command === "x") inputArea.cut()
            ctrlActive = false
            shiftActive = false
            focusInput()
            return
        }

        replaceSelection(value)
        if (shiftActive)
            shiftActive = false
    }

    function deleteBackward() {
        var start = Math.min(inputArea.selectionStart, inputArea.selectionEnd)
        var end = Math.max(inputArea.selectionStart, inputArea.selectionEnd)
        if (start !== end) {
            inputArea.remove(start, end)
            inputArea.cursorPosition = start
        } else if (inputArea.cursorPosition > 0) {
            var position = inputArea.cursorPosition
            inputArea.remove(position - 1, position)
            inputArea.cursorPosition = position - 1
        }
        focusInput()
    }

    function deleteForward() {
        var start = Math.min(inputArea.selectionStart, inputArea.selectionEnd)
        var end = Math.max(inputArea.selectionStart, inputArea.selectionEnd)
        if (start !== end) {
            inputArea.remove(start, end)
            inputArea.cursorPosition = start
        } else if (inputArea.cursorPosition < inputArea.length) {
            inputArea.remove(inputArea.cursorPosition, inputArea.cursorPosition + 1)
        }
        focusInput()
    }

    function moveHorizontal(delta) {
        inputArea.cursorPosition = Math.max(0, Math.min(inputArea.length,
                                                       inputArea.cursorPosition + delta))
        focusInput()
    }

    function moveLineBoundary(toEnd) {
        var position = inputArea.cursorPosition
        var text = inputArea.text
        if (toEnd) {
            var lineEnd = text.indexOf("\n", position)
            inputArea.cursorPosition = lineEnd < 0 ? text.length : lineEnd
        } else {
            var lineStart = text.lastIndexOf("\n", Math.max(0, position - 1))
            inputArea.cursorPosition = lineStart + 1
        }
        focusInput()
    }

    function moveVertical(direction) {
        var text = inputArea.text
        var position = inputArea.cursorPosition
        var lineStart = text.lastIndexOf("\n", Math.max(0, position - 1)) + 1
        var column = position - lineStart

        if (direction < 0) {
            if (lineStart === 0)
                return
            var previousEnd = lineStart - 1
            var previousStart = text.lastIndexOf("\n", Math.max(0, previousEnd - 1)) + 1
            inputArea.cursorPosition = previousStart
                    + Math.min(column, previousEnd - previousStart)
        } else {
            var currentEnd = text.indexOf("\n", position)
            if (currentEnd < 0)
                return
            var nextStart = currentEnd + 1
            var nextEnd = text.indexOf("\n", nextStart)
            if (nextEnd < 0)
                nextEnd = text.length
            inputArea.cursorPosition = nextStart + Math.min(column, nextEnd - nextStart)
        }
        focusInput()
    }

    function performCopy() {
        var originalPosition = inputArea.cursorPosition
        var temporarySelection = !hasSelection()
        if (temporarySelection)
            inputArea.selectAll()
        inputArea.copy()
        if (temporarySelection)
            inputArea.select(originalPosition, originalPosition)
        lastAction = "Copied"
        focusInput()
    }

    function evaluateArithmetic(expression) {
        var source = expression.replace(/\s+/g, "")
        if (source.length === 0)
            throw new Error("Enter a calculation first")
        if (!/^[0-9+\-*\/().]+$/.test(source))
            throw new Error("Only numbers and + - * / ( ) are allowed")

        var position = 0

        function parseNumber() {
            var start = position
            var digitCount = 0
            while (position < source.length
                   && source.charAt(position) >= "0"
                   && source.charAt(position) <= "9") {
                ++position
                ++digitCount
            }
            if (position < source.length && source.charAt(position) === ".") {
                ++position
                while (position < source.length
                       && source.charAt(position) >= "0"
                       && source.charAt(position) <= "9") {
                    ++position
                    ++digitCount
                }
            }
            if (digitCount === 0)
                throw new Error("A number is missing")

            var value = Number(source.slice(start, position))
            if (!isFinite(value))
                throw new Error("The number is too large")
            return value
        }

        function parseFactor() {
            if (source.charAt(position) === "+") {
                ++position
                return parseFactor()
            }
            if (source.charAt(position) === "-") {
                ++position
                return -parseFactor()
            }
            if (source.charAt(position) === "(") {
                ++position
                var grouped = parseExpression()
                if (source.charAt(position) !== ")")
                    throw new Error("A closing parenthesis is missing")
                ++position
                return grouped
            }
            return parseNumber()
        }

        function parseTerm() {
            var value = parseFactor()
            while (position < source.length) {
                var operator = source.charAt(position)
                if (operator !== "*" && operator !== "/")
                    break
                ++position
                var right = parseFactor()
                if (operator === "*") {
                    value *= right
                } else {
                    if (right === 0)
                        throw new Error("Cannot divide by zero")
                    value /= right
                }
            }
            return value
        }

        function parseExpression() {
            var value = parseTerm()
            while (position < source.length) {
                var operator = source.charAt(position)
                if (operator !== "+" && operator !== "-")
                    break
                ++position
                var right = parseTerm()
                value = operator === "+" ? value + right : value - right
            }
            return value
        }

        var result = parseExpression()
        if (position !== source.length)
            throw new Error("The calculation format is incomplete")
        if (!isFinite(result))
            throw new Error("The result is out of range")
        return result
    }

    function formatCalculatorResult(value) {
        if (Math.abs(value) < 0.000000000001)
            value = 0
        return String(Number(value.toPrecision(12)))
    }

    function currentNumericValue() {
        var fullText = inputArea.text
        if (fullText.trim().length === 0)
            return NaN

        var cursor = inputArea.cursorPosition
        var lineStart = fullText.lastIndexOf("\n", Math.max(0, cursor - 1)) + 1
        var lineEnd = fullText.indexOf("\n", cursor)
        if (lineEnd < 0)
            lineEnd = fullText.length
        var expression = fullText.slice(lineStart, lineEnd).trim()

        try {
            return evaluateArithmetic(expression)
        } catch (error) {
            return NaN
        }
    }

    function formatBaseValue(value, base, prefix, maximumFractionDigits) {
        if (!isFinite(value))
            return "—"
        if (Math.abs(value) > 9007199254740991)
            return "Out of range"
        if (Math.abs(value) < 0.000000000001)
            value = 0

        var sign = value < 0 ? "-" : ""
        var absolute = Math.abs(value)
        var integerPart = Math.floor(absolute)
        var result = integerPart.toString(base).toUpperCase()
        var fraction = absolute - integerPart
        var fractionText = ""

        for (var i = 0; i < maximumFractionDigits && fraction > 0.000000000001; ++i) {
            fraction *= base
            var digit = Math.floor(fraction + 0.000000000001)
            fraction -= digit
            fractionText += digit.toString(base).toUpperCase()
        }
        while (fractionText.length > 0
               && fractionText.charAt(fractionText.length - 1) === "0")
            fractionText = fractionText.slice(0, fractionText.length - 1)

        return sign + prefix + result + (fractionText.length > 0 ? "." + fractionText : "")
    }

    function calculateCurrentLine() {
        var fullText = inputArea.text
        var cursor = inputArea.cursorPosition
        var lineStart = fullText.lastIndexOf("\n", Math.max(0, cursor - 1)) + 1
        var lineEnd = fullText.indexOf("\n", cursor)
        if (lineEnd < 0)
            lineEnd = fullText.length
        var expression = fullText.slice(lineStart, lineEnd).trim()

        try {
            var resultText = formatCalculatorResult(evaluateArithmetic(expression))
            inputArea.remove(lineStart, lineEnd)
            inputArea.insert(lineStart, resultText)
            inputArea.cursorPosition = lineStart + resultText.length
            calculatorResultReady = true
            calculationError = ""
            lastAction = expression + " = " + resultText
        } catch (error) {
            calculatorResultReady = false
            calculationError = error.message || String(error)
            lastAction = "Calculator error: " + calculationError
        }
        focusInput()
    }

    function activateKey(keyData) {
        var role = keyData.role || "character"
        lastAction = keyData.label || keyData.value || "Key"

        if (role === "character") insertCharacter(keyData)
        else if (role === "backspace") deleteBackward()
        else if (role === "delete") deleteForward()
        else if (role === "tab") replaceSelection("    ")
        else if (role === "enter") {
            if (keyboardMode === 1)
                calculateCurrentLine()
            else
                replaceSelection("\n")
        }
        else if (role === "space") replaceSelection(" ")
        else if (role === "left") moveHorizontal(-1)
        else if (role === "right") moveHorizontal(1)
        else if (role === "up") moveVertical(-1)
        else if (role === "down") moveVertical(1)
        else if (role === "home") moveLineBoundary(false)
        else if (role === "end") moveLineBoundary(true)
        else if (role === "pageup") inputArea.cursorPosition = 0
        else if (role === "pagedown") inputArea.cursorPosition = inputArea.length
        else if (role === "selectall") inputArea.selectAll()
        else if (role === "clear") {
            inputArea.clear()
            calculatorResultReady = false
            calculationError = ""
        }
        else if (role === "shift") shiftActive = !shiftActive
        else if (role === "caps") capsLock = !capsLock
        else if (role === "ctrl") ctrlActive = !ctrlActive
        else if (role === "alt") altActive = !altActive
        else if (role === "escape") {
            shiftActive = false
            ctrlActive = false
            altActive = false
            inputArea.select(inputArea.cursorPosition, inputArea.cursorPosition)
        }
        focusInput()
    }

    // Vector glyphs drawn in QML so the EVM does not depend on optional Unicode
    // symbols that are missing from its default font package.
    component KeyGlyph: Canvas {
        id: glyphCanvas

        required property string glyph
        property color glyphColor: "#f4f7fb"

        implicitWidth: root.keyFontSize
        implicitHeight: root.keyFontSize

        onGlyphChanged: requestPaint()
        onGlyphColorChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d")
            var w = width
            var h = height
            ctx.clearRect(0, 0, w, h)
            ctx.strokeStyle = glyphColor
            ctx.lineWidth = Math.max(2.2, w * 0.075)
            ctx.lineCap = "round"
            ctx.lineJoin = "round"

            function stroke(points, closePath) {
                ctx.beginPath()
                ctx.moveTo(points[0][0] * w, points[0][1] * h)
                for (var i = 1; i < points.length; ++i)
                    ctx.lineTo(points[i][0] * w, points[i][1] * h)
                if (closePath)
                    ctx.closePath()
                ctx.stroke()
            }

            if (glyph === "left") {
                stroke([[0.82, 0.50], [0.20, 0.50], [0.40, 0.29]], false)
                stroke([[0.20, 0.50], [0.40, 0.71]], false)
            } else if (glyph === "right") {
                stroke([[0.18, 0.50], [0.80, 0.50], [0.60, 0.29]], false)
                stroke([[0.80, 0.50], [0.60, 0.71]], false)
            } else if (glyph === "up") {
                stroke([[0.50, 0.82], [0.50, 0.20], [0.29, 0.40]], false)
                stroke([[0.50, 0.20], [0.71, 0.40]], false)
            } else if (glyph === "down") {
                stroke([[0.50, 0.18], [0.50, 0.80], [0.29, 0.60]], false)
                stroke([[0.50, 0.80], [0.71, 0.60]], false)
            } else if (glyph === "enter") {
                stroke([[0.82, 0.20], [0.82, 0.60], [0.22, 0.60], [0.42, 0.38]], false)
                stroke([[0.22, 0.60], [0.42, 0.82]], false)
            } else if (glyph === "shift" || glyph === "caps") {
                stroke([[0.18, 0.52], [0.50, 0.18], [0.82, 0.52],
                        [0.65, 0.52], [0.65, 0.80], [0.35, 0.80],
                        [0.35, 0.52]], true)
                if (glyph === "caps")
                    stroke([[0.28, 0.92], [0.72, 0.92]], false)
            } else if (glyph === "backspace") {
                stroke([[0.13, 0.50], [0.35, 0.22], [0.88, 0.22],
                        [0.88, 0.78], [0.35, 0.78]], true)
                stroke([[0.50, 0.36], [0.72, 0.64]], false)
                stroke([[0.72, 0.36], [0.50, 0.64]], false)
            } else if (glyph === "delete") {
                stroke([[0.12, 0.22], [0.65, 0.22], [0.88, 0.50],
                        [0.65, 0.78], [0.12, 0.78]], true)
                stroke([[0.30, 0.36], [0.52, 0.64]], false)
                stroke([[0.52, 0.36], [0.30, 0.64]], false)
            } else if (glyph === "tab") {
                stroke([[0.12, 0.26], [0.12, 0.74]], false)
                stroke([[0.88, 0.26], [0.88, 0.74]], false)
                stroke([[0.22, 0.38], [0.70, 0.38], [0.54, 0.24]], false)
                stroke([[0.70, 0.38], [0.54, 0.52]], false)
                stroke([[0.78, 0.66], [0.30, 0.66], [0.46, 0.52]], false)
                stroke([[0.30, 0.66], [0.46, 0.80]], false)
            } else if (glyph === "copy") {
                stroke([[0.32, 0.28], [0.83, 0.28], [0.83, 0.82], [0.32, 0.82]], true)
                stroke([[0.17, 0.67], [0.17, 0.14], [0.68, 0.14]], false)
            } else if (glyph === "paste") {
                stroke([[0.24, 0.24], [0.76, 0.24], [0.76, 0.84], [0.24, 0.84]], true)
                stroke([[0.38, 0.14], [0.62, 0.14], [0.62, 0.34], [0.38, 0.34]], true)
            } else if (glyph === "clear") {
                stroke([[0.28, 0.30], [0.72, 0.30], [0.67, 0.84], [0.33, 0.84]], true)
                stroke([[0.22, 0.22], [0.78, 0.22]], false)
                stroke([[0.40, 0.14], [0.60, 0.14]], false)
            }
        }
    }

    component KeyButton: Button {
        id: keyButton

        required property var keyData
        property bool modifierActive: (keyData.role === "shift" && root.shiftActive)
                                      || (keyData.role === "caps" && root.capsLock)
                                      || (keyData.role === "ctrl" && root.ctrlActive)
                                      || (keyData.role === "alt" && root.altActive)

        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredWidth: 72 * (keyData.weight || 1.0)
        Layout.minimumWidth: 30
        Layout.minimumHeight: 34

        hoverEnabled: true
        focusPolicy: Qt.NoFocus
        onClicked: root.activateKey(keyData)

        background: Rectangle {
            radius: root.compact ? 6 : 8
            color: keyButton.modifierActive ? "#0e6ddd"
                 : keyButton.down           ? "#25364a"
                 : keyButton.hovered        ? "#202a36"
                                            : "#171d25"
            border.width: keyButton.modifierActive ? 1.5 : 1
            border.color: keyButton.modifierActive ? "#28a8ff" : "#2b3540"

            Behavior on color { ColorAnimation { duration: 90 } }
        }

        contentItem: Item {
            clip: true

            Column {
                anchors.centerIn: parent
                spacing: 0
                visible: keyButton.keyData.top !== undefined

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: keyButton.keyData.top || ""
                    color: root.shiftActive ? "#28a8ff" : "#f4f7fb"
                    font.pixelSize: root.pairedKeyFontSize
                    font.bold: true
                    height: implicitHeight
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: keyButton.keyData.bottom || ""
                    color: "#f4f7fb"
                    font.pixelSize: root.pairedKeyFontSize
                    font.bold: true
                    height: implicitHeight
                }
            }

            Row {
                id: normalKeyContent
                anchors.centerIn: parent
                spacing: keyButton.keyData.icon !== undefined
                         ? (root.compact ? 5 : 9) : 0
                visible: keyButton.keyData.top === undefined

                KeyGlyph {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: keyButton.keyData.icon !== undefined
                    glyph: keyButton.keyData.icon || ""
                    glyphColor: "#f4f7fb"
                    width: visible ? root.keyFontSize * 0.92 : 0
                    height: width
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.displayedLabel(keyButton.keyData)
                    color: "#f4f7fb"
                    width: Math.min(implicitWidth,
                                    Math.max(1, keyButton.availableWidth
                                             - (keyButton.keyData.icon !== undefined
                                                ? root.keyFontSize * 0.92
                                                  + normalKeyContent.spacing : 0)
                                             - 12))
                    height: Math.max(1, keyButton.availableHeight - 8)
                    font.pixelSize: root.keyFontSize
                    font.bold: true
                    fontSizeMode: Text.Fit
                    minimumPixelSize: Math.round(root.keyFontSize * 0.72)
                    wrapMode: Text.NoWrap
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    component ActionButton: Button {
        id: actionButton
        property color accentColor: "#1685f8"
        property string glyphName: ""

        implicitHeight: root.compact ? 42 : 52
        hoverEnabled: true
        focusPolicy: Qt.NoFocus
        background: Rectangle {
            radius: 8
            color: actionButton.down ? "#16283b"
                 : actionButton.hovered ? "#111d2b"
                                      : "#0b1119"
            border.width: 1
            border.color: actionButton.accentColor
        }
        contentItem: Item {
            clip: true

            Row {
                id: actionContent
                anchors.centerIn: parent
                spacing: actionButton.glyphName !== "" ? 7 : 0
                KeyGlyph {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: actionButton.glyphName !== ""
                    glyph: actionButton.glyphName
                    glyphColor: actionButton.accentColor
                    width: visible ? (root.compact ? 24 : 30) : 0
                    height: width
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: actionButton.text
                    color: actionButton.accentColor
                    width: Math.min(implicitWidth,
                                    Math.max(1, actionButton.availableWidth
                                             - (actionButton.glyphName !== ""
                                                ? (root.compact ? 24 : 30)
                                                  + actionContent.spacing : 0)
                                             - 12))
                    height: Math.max(1, actionButton.availableHeight - 8)
                    font.pixelSize: root.compact ? 15 : 18
                    font.bold: true
                    fontSizeMode: Text.Fit
                    minimumPixelSize: 12
                    wrapMode: Text.NoWrap
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: pageColumn.implicitHeight + root.pageMargin * 2
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
        }

        ColumnLayout {
            id: pageColumn
            x: root.pageMargin
            y: root.pageMargin
            width: parent.width - root.pageMargin * 2
            spacing: root.compact ? 12 : 18

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: root.compact ? 54 : 72
                spacing: 14

                Rectangle {
                    Layout.preferredWidth: root.compact ? 42 : 50
                    Layout.preferredHeight: root.compact ? 42 : 50
                    radius: 10
                    color: "#071729"
                    border.color: "#0e78c7"

                    Image {
                        anchors.centerIn: parent
                        width: parent.width * 0.58
                        height: width
                        source: "qrc:/assets/icons/keyboard.svg"
                        sourceSize: Qt.size(64, 64)
                        fillMode: Image.PreserveAspectFit
                    }
                }

                ColumnLayout {
                    spacing: 1
                    Text {
                        text: "Virtual Keyboard"
                        color: "#f4f7fb"
                        font.pixelSize: root.compact ? 22 : 27
                        font.bold: true
                    }
                    Text {
                        text: "On-screen keyboard for input and control"
                        color: "#9fb0c5"
                        font.pixelSize: root.compact ? 13 : 16
                    }
                }

                Item { Layout.fillWidth: true }

                Text {
                    text: root.lastAction
                    color: "#56708c"
                    font.pixelSize: 13
                    visible: !root.compact
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.compact ? 78 : 104
                radius: 12
                color: "#070d14"
                border.color: root.calculationError !== "" ? "#ef4444"
                              : inputArea.activeFocus ? "#1685f8" : "#17435f"
                border.width: 1

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: root.compact ? 10 : 14
                    spacing: 10

                    TextArea {
                        id: inputArea
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        placeholderText: "Type here..."
                        placeholderTextColor: "#718096"
                        color: "#e8eef7"
                        selectionColor: "#1769c2"
                        selectedTextColor: "#ffffff"
                        // Doubled for readability on the physical 1920x1200 panel.
                        font.pixelSize: root.compact ? 34 : 42
                        wrapMode: TextEdit.Wrap
                        selectByMouse: true
                        persistentSelection: true
                        leftPadding: 8
                        rightPadding: 8
                        topPadding: 8
                        bottomPadding: 8
                        background: Rectangle { color: "transparent" }
                    }

                    ActionButton {
                        text: ""
                        glyphName: "delete"
                        Layout.preferredWidth: root.compact ? 48 : 58
                        accentColor: "#a8b7c8"
                        onClicked: root.deleteForward()
                    }
                    ActionButton {
                        text: ""
                        glyphName: "left"
                        Layout.preferredWidth: root.compact ? 48 : 58
                        accentColor: "#a8b7c8"
                        onClicked: root.moveHorizontal(-1)
                    }
                    ActionButton {
                        text: ""
                        glyphName: "right"
                        Layout.preferredWidth: root.compact ? 48 : 58
                        accentColor: "#a8b7c8"
                        onClicked: root.moveHorizontal(1)
                    }
                    ActionButton {
                        text: "Clear"
                        Layout.preferredWidth: root.compact ? 72 : 92
                        onClicked: {
                            inputArea.clear()
                            root.focusInput()
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.compact ? 460 : 590
                Layout.minimumHeight: 420
                radius: 12
                color: "#0a0f15"
                border.color: "#28323d"
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: root.compact ? 10 : 16
                    spacing: root.keyGap

                    Repeater {
                        model: root.activeRows

                        delegate: RowLayout {
                            id: keyboardRow
                            required property var modelData

                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: root.keyGap

                            Repeater {
                                model: keyboardRow.modelData

                                delegate: KeyButton {
                                    required property var modelData
                                    keyData: modelData
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.compact ? 132 : 160
                radius: 12
                color: "#090e14"
                border.color: "#28323d"
                border.width: 1

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: root.compact ? 12 : 20
                    spacing: root.compact ? 14 : 24

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 10
                        Text {
                            text: "Keyboard Mode"
                            color: "#e8eef7"
                            font.pixelSize: root.compact ? 15 : 17
                            font.bold: true
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Repeater {
                                model: ["ABC", "123", "#+=", "Arrows"]
                                delegate: Button {
                                    id: modeButton
                                    required property int index
                                    required property string modelData
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: root.compact ? 44 : 58
                                    focusPolicy: Qt.NoFocus
                                    onClicked: root.keyboardMode = index
                                    background: Rectangle {
                                        radius: 8
                                        color: root.keyboardMode === modeButton.index
                                               ? "#0d6fee" : "#0c1118"
                                        border.color: root.keyboardMode === modeButton.index
                                                      ? "#28a8ff" : "#293440"
                                    }
                                    contentItem: Text {
                                        text: modeButton.modelData
                                        color: "#f4f7fb"
                                        font.pixelSize: root.compact ? 14 : 17
                                        font.bold: root.keyboardMode === modeButton.index
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillHeight: true
                        Layout.preferredWidth: 1
                        color: "#202a35"
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 10
                        Text {
                            text: "Input Control"
                            color: "#e8eef7"
                            font.pixelSize: root.compact ? 15 : 17
                            font.bold: true
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            ActionButton {
                                Layout.fillWidth: true
                                text: "Copy"
                                accentColor: "#dce6f2"
                                onClicked: root.performCopy()
                            }
                            ActionButton {
                                Layout.fillWidth: true
                                text: "Paste"
                                accentColor: "#dce6f2"
                                onClicked: {
                                    inputArea.paste()
                                    root.lastAction = "Pasted"
                                    root.focusInput()
                                }
                            }
                            ActionButton {
                                Layout.fillWidth: true
                                text: "Clear All"
                                accentColor: "#dce6f2"
                                onClicked: {
                                    inputArea.clear()
                                    root.lastAction = "Cleared"
                                    root.focusInput()
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillHeight: true
                        Layout.preferredWidth: 1
                        color: "#202a35"
                    }

                    ColumnLayout {
                        Layout.preferredWidth: root.compact ? 280 : 370
                        Layout.fillHeight: true
                        spacing: 4

                        Text {
                            text: "Number Output"
                            color: "#e8eef7"
                            font.pixelSize: root.compact ? 15 : 17
                            font.bold: true
                        }

                        Repeater {
                            model: [
                                { label: "HEX", value: root.hexOutput, accent: "#28a8ff" },
                                { label: "DEC", value: root.decimalOutput, accent: "#f4f7fb" },
                                { label: "BINARY", value: root.binaryOutput, accent: "#22d3a3" }
                            ]

                            delegate: RowLayout {
                                id: outputRow
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: 7

                                Text {
                                    Layout.preferredWidth: root.compact ? 52 : 66
                                    text: outputRow.modelData.label
                                    color: outputRow.modelData.accent
                                    font.pixelSize: root.compact ? 13 : 15
                                    font.bold: true
                                    verticalAlignment: Text.AlignVCenter
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    Layout.minimumHeight: root.compact ? 24 : 28
                                    radius: 5
                                    color: "#060b11"
                                    border.color: "#273544"

                                    Text {
                                        anchors.fill: parent
                                        anchors.leftMargin: 8
                                        anchors.rightMargin: 8
                                        text: outputRow.modelData.value
                                        color: outputRow.modelData.accent
                                        font.family: "monospace"
                                        font.pixelSize: root.compact ? 14 : 17
                                        font.bold: outputRow.modelData.label === "DEC"
                                        elide: Text.ElideMiddle
                                        horizontalAlignment: Text.AlignRight
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
