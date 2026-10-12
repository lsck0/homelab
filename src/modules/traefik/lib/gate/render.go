package main

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"math"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// The plate under a shape: the label in a 5x7 pixel font, scaled up, on white, readable on a light and a dark page.
const (
	glyphColumns  = 5
	glyphRows     = 7
	glyphScale    = 3
	glyphGapPx    = 3
	platePaddingX = 8
	platePaddingY = 7
	plateMarginPx = 6
	plateRadiusPx = 6
	// samples per pixel side at shape edges: 4x4 smooths them without blurring the plates' pixel font
	supersample = 4
)

// An onion route's rows: each address in two lines of the same font, smaller, on a panel, its label's plate beside it.
const (
	rowPitchPx       = 72
	rowMarginPx      = 12
	rowPaddingPx     = 12
	rowRadiusPx      = 10
	addressScale     = 2
	addressGapPx     = 1
	addressLineGapPx = 6
	// two lines of the 62 characters fit beside the plate at the scene's width
	addressLines = 2
)

// Lowercase hex and onion base32: a, b, d and e stay distinct from 8, 6, 0 and 3 at a glance; the zero carries a
// stroke; g, q and y differ in their tops and tails.
var glyphs = map[rune][glyphRows]string{
	'0': {".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."},
	'1': {"..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."},
	'2': {".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"},
	'3': {"####.", "....#", "....#", ".###.", "....#", "....#", "####."},
	'4': {"...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."},
	'5': {"#####", "#....", "####.", "....#", "....#", "#...#", ".###."},
	'6': {"..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."},
	'7': {"#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."},
	'8': {".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."},
	'9': {".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."},
	'a': {".....", ".....", ".###.", "....#", ".####", "#...#", ".####"},
	'b': {"#....", "#....", "####.", "#...#", "#...#", "#...#", "####."},
	'c': {".....", ".....", ".####", "#....", "#....", "#....", ".####"},
	'd': {"....#", "....#", ".####", "#...#", "#...#", "#...#", ".####"},
	'e': {".....", ".....", ".###.", "#...#", "#####", "#....", ".####"},
	'f': {"..##.", ".#...", "####.", ".#...", ".#...", ".#...", ".#..."},
	'g': {".....", ".####", "#...#", "#...#", ".####", "....#", ".###."},
	'h': {"#....", "#....", "####.", "#...#", "#...#", "#...#", "#...#"},
	'i': {"..#..", ".....", ".##..", "..#..", "..#..", "..#..", ".###."},
	'j': {"...#.", ".....", "..##.", "...#.", "...#.", "#..#.", ".##.."},
	'k': {"#....", "#....", "#..#.", "#.#..", "##...", "#.#..", "#..#."},
	'l': {".##..", "..#..", "..#..", "..#..", "..#..", "..#..", "..##."},
	'm': {".....", ".....", "##.#.", "#.#.#", "#.#.#", "#.#.#", "#.#.#"},
	'n': {".....", ".....", "####.", "#...#", "#...#", "#...#", "#...#"},
	'o': {".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###."},
	'p': {".....", "####.", "#...#", "#...#", "####.", "#....", "#...."},
	'q': {".....", ".####", "#...#", "#...#", ".####", "....#", "....#"},
	'r': {".....", ".....", "#.##.", "##..#", "#....", "#....", "#...."},
	's': {".....", ".....", ".####", "#....", ".###.", "....#", "####."},
	't': {".#...", ".#...", "####.", ".#...", ".#...", ".#..#", "..##."},
	'u': {".....", ".....", "#...#", "#...#", "#...#", "#..##", ".##.#"},
	'v': {".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#.."},
	'w': {".....", ".....", "#...#", "#...#", "#.#.#", "#.#.#", ".#.#."},
	'x': {".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"},
	'y': {".....", "#...#", "#...#", "#...#", ".####", "....#", ".###."},
	'z': {".....", ".....", "#####", "...#.", "..#..", ".#...", "#####"},
	'.': {".....", ".....", ".....", ".....", ".....", ".##..", ".##.."},
}

// Tailwind's 500 shades: mid tones that hold contrast against slate-50 and slate-800 alike.
var shapeColors = []color.NRGBA{
	{0x0e, 0xa5, 0xe9, 0xff}, // sky
	{0xf5, 0x9e, 0x0b, 0xff}, // amber
	{0x10, 0xb9, 0x81, 0xff}, // emerald
	{0xf4, 0x3f, 0x5e, 0xff}, // rose
	{0x8b, 0x5c, 0xf6, 0xff}, // violet
	{0x14, 0xb8, 0xa6, 0xff}, // teal
	{0xf9, 0x73, 0x16, 0xff}, // orange
}

var (
	plateFill   = color.NRGBA{0xff, 0xff, 0xff, 0xff}
	plateBorder = color.NRGBA{0x94, 0xa3, 0xb8, 0xff}
	plateInk    = color.NRGBA{0x0f, 0x17, 0x2a, 0xff}
	// slate-100: a row's panel sets its white plate apart
	rowFill = color.NRGBA{0xf1, 0xf5, 0xf9, 0xff}
)

// A square's half side and a diamond's half diagonal per unit of circumradius, so shapes of one size look as big.
const (
	squareHalfPerSize  = 0.86
	diamondHalfPerSize = 1.12
	triangleHalfBase   = 0.866
	triangleBaseDrop   = 0.5
)

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

// blend paints c over the pixel with coverage in [0,1], straight alpha compositing.
func blend(canvas *image.NRGBA, x, y int, c color.NRGBA, coverage float64) {
	if coverage <= 0 || !(image.Point{x, y}.In(canvas.Rect)) {
		return
	}
	dst := canvas.NRGBAAt(x, y)
	sa := coverage * float64(c.A) / 0xff
	da := float64(dst.A) / 0xff
	outA := sa + da*(1-sa)
	mix := func(s, d uint8) uint8 {
		return uint8(math.Round((float64(s)*sa + float64(d)*da*(1-sa)) / outA))
	}
	canvas.SetNRGBA(x, y, color.NRGBA{mix(c.R, dst.R), mix(c.G, dst.G), mix(c.B, dst.B), uint8(math.Round(outA * 0xff))})
}

// fill paints the region inside() covers within its bounding box, supersampled at the edges.
func fill(canvas *image.NRGBA, bounds image.Rectangle, c color.NRGBA, inside func(x, y float64) bool) {
	step := 1.0 / supersample
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			hits := 0
			for sy := range supersample {
				for sx := range supersample {
					if inside(float64(x)+(float64(sx)+0.5)*step, float64(y)+(float64(sy)+0.5)*step) {
						hits++
					}
				}
			}
			blend(canvas, x, y, c, float64(hits)/(supersample*supersample))
		}
	}
}

func edgeSide(ax, ay, bx, by, px, py float64) float64 {
	return (bx-ax)*(py-ay) - (by-ay)*(px-ax)
}

func shapeInside(o Object) func(x, y float64) bool {
	switch o.Shape {
	case ShapeCircle:
		return func(x, y float64) bool { return math.Hypot(x-o.X, y-o.Y) <= o.SizePx }
	case ShapeSquare:
		half := o.SizePx * squareHalfPerSize
		return func(x, y float64) bool { return math.Abs(x-o.X) <= half && math.Abs(y-o.Y) <= half }
	case ShapeDiamond:
		half := o.SizePx * diamondHalfPerSize
		return func(x, y float64) bool { return math.Abs(x-o.X)+math.Abs(y-o.Y) <= half }
	case ShapeTriangle:
		ax, ay := o.X, o.Y-o.SizePx
		bx, by := o.X-o.SizePx*triangleHalfBase, o.Y+o.SizePx*triangleBaseDrop
		cx, cy := o.X+o.SizePx*triangleHalfBase, by
		return func(x, y float64) bool {
			return edgeSide(ax, ay, bx, by, x, y) <= 0 && edgeSide(bx, by, cx, cy, x, y) <= 0 && edgeSide(cx, cy, ax, ay, x, y) <= 0
		}
	case ShapeCount:
	}
	panic("render: no such shape")
}

func roundedRectInside(r image.Rectangle, radius float64) func(x, y float64) bool {
	return func(x, y float64) bool {
		nearestX := math.Max(float64(r.Min.X)+radius, math.Min(x, float64(r.Max.X)-radius))
		nearestY := math.Max(float64(r.Min.Y)+radius, math.Min(y, float64(r.Max.Y)-radius))
		return math.Hypot(x-nearestX, y-nearestY) <= radius
	}
}

func textWidthPx(chars, scale, gapPx int) int {
	return chars*glyphColumns*scale + (chars-1)*gapPx
}

// textDraw sets text in the pixel font, each font pixel a scale x scale square, its top left corner at left, top.
func textDraw(canvas *image.NRGBA, left, top int, text string, scale, gapPx int) {
	for i, char := range []rune(text) {
		glyph, found := glyphs[char]
		if !found {
			panic("render: no glyph for " + string(char))
		}
		originX := left + i*(glyphColumns*scale+gapPx)
		for row, bits := range glyph {
			for column, bit := range bits {
				if bit != '#' {
					continue
				}
				for dy := range scale {
					for dx := range scale {
						blend(canvas, originX+column*scale+dx, top+row*scale+dy, plateInk, 1)
					}
				}
			}
		}
	}
}

func plateSize() image.Point {
	return image.Pt(textWidthPx(labelChars, glyphScale, glyphGapPx)+2*platePaddingX, glyphRows*glyphScale+2*platePaddingY)
}

func panelDraw(canvas *image.NRGBA, outer image.Rectangle, inside color.NRGBA, radiusPx float64) {
	fill(canvas, outer, plateBorder, roundedRectInside(outer, radiusPx))
	inner := outer.Inset(1)
	fill(canvas, inner, inside, roundedRectInside(inner, radiusPx-1))
}

func plateDraw(canvas *image.NRGBA, topLeft image.Point, label string) {
	panelDraw(canvas, image.Rectangle{Min: topLeft, Max: topLeft.Add(plateSize())}, plateFill, plateRadiusPx)
	textDraw(canvas, topLeft.X+platePaddingX, topLeft.Y+platePaddingY, label, glyphScale, glyphGapPx)
}

func objectDraw(canvas *image.NRGBA, o Object) {
	reach := int(math.Ceil(o.SizePx*diamondHalfPerSize)) + 1
	center := image.Pt(int(o.X), int(o.Y))
	bounds := image.Rectangle{Min: center.Sub(image.Pt(reach, reach)), Max: center.Add(image.Pt(reach, reach))}
	fill(canvas, bounds.Intersect(canvas.Rect), shapeColors[o.ColorID], shapeInside(o))
	plateDraw(canvas, image.Pt(int(math.Round(o.X))-plateSize().X/2, int(math.Round(o.Y+o.SizePx+plateMarginPx))), o.Label)
}

// rowDraw is the index-th row: its panel, the address in lines on the left, the label's plate on the right.
func rowDraw(canvas *image.NRGBA, index int, row Row) {
	panel := image.Rect(rowMarginPx, rowMarginPx+index*rowPitchPx, canvasWidthPx-rowMarginPx, (index+1)*rowPitchPx)
	panelDraw(canvas, panel, rowFill, rowRadiusPx)
	plate := plateSize()
	plateTopLeft := image.Pt(panel.Max.X-rowPaddingPx-plate.X, panel.Min.Y+(panel.Dy()-plate.Y)/2)
	plateDraw(canvas, plateTopLeft, row.Code)
	lineChars := (len(row.Address) + addressLines - 1) / addressLines
	if panel.Min.X+rowPaddingPx+textWidthPx(lineChars, addressScale, addressGapPx) >= plateTopLeft.X {
		panic("render: an address runs into its plate")
	}
	lineHeight := glyphRows*addressScale + addressLineGapPx
	top := panel.Min.Y + (panel.Dy()-addressLines*lineHeight+addressLineGapPx)/2
	for line := range addressLines {
		text := row.Address[min(line*lineChars, len(row.Address)):min((line+1)*lineChars, len(row.Address))]
		textDraw(canvas, panel.Min.X+rowPaddingPx, top+line*lineHeight, text, addressScale, addressGapPx)
	}
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// puzzleSize is the picture's size in pixels: the scene's, or as many rows as the puzzle has.
func puzzleSize(puzzle Puzzle) image.Point {
	if len(puzzle.Rows) > 0 {
		return image.Pt(canvasWidthPx, rowMarginPx+len(puzzle.Rows)*rowPitchPx)
	}
	return image.Pt(canvasWidthPx, canvasHeightPx)
}

// puzzleRender draws the scene or the rows as a png with a transparent background; nothing but pixels carries the
// labels and the addresses, so a proxy rewriting the page's text leaves them as the lab drew them.
func puzzleRender(puzzle Puzzle) ([]byte, error) {
	canvas := image.NewNRGBA(image.Rectangle{Max: puzzleSize(puzzle)})
	for _, o := range puzzle.Objects {
		objectDraw(canvas, o)
	}
	for i, row := range puzzle.Rows {
		rowDraw(canvas, i, row)
	}
	var out bytes.Buffer
	encoder := png.Encoder{CompressionLevel: png.BestSpeed}
	if err := encoder.Encode(&out, canvas); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}
