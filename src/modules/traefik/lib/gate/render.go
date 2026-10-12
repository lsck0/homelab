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

// Lowercase hex: a, b, d and e stay distinct from 8, 6, 0 and 3 at a glance; the zero carries a stroke.
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

func plateDraw(canvas *image.NRGBA, o Object) {
	textWidth := labelChars*glyphColumns*glyphScale + (labelChars-1)*glyphGapPx
	width := textWidth + 2*platePaddingX
	height := glyphRows*glyphScale + 2*platePaddingY
	left := int(math.Round(o.X)) - width/2
	top := int(math.Round(o.Y + o.SizePx + plateMarginPx))
	outer := image.Rect(left, top, left+width, top+height)
	fill(canvas, outer, plateBorder, roundedRectInside(outer, plateRadiusPx))
	inner := outer.Inset(1)
	fill(canvas, inner, plateFill, roundedRectInside(inner, plateRadiusPx-1))
	for i, char := range o.Label {
		glyph := glyphs[char]
		originX := left + platePaddingX + i*(glyphColumns*glyphScale+glyphGapPx)
		originY := top + platePaddingY
		for row, bits := range glyph {
			for column, bit := range bits {
				if bit != '#' {
					continue
				}
				for dy := range glyphScale {
					for dx := range glyphScale {
						blend(canvas, originX+column*glyphScale+dx, originY+row*glyphScale+dy, plateInk, 1)
					}
				}
			}
		}
	}
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// puzzleRender draws the scene as a png with a transparent background; nothing but pixels carries the labels.
func puzzleRender(puzzle Puzzle) ([]byte, error) {
	canvas := image.NewNRGBA(image.Rect(0, 0, canvasWidthPx, canvasHeightPx))
	for _, o := range puzzle.Objects {
		reach := int(math.Ceil(o.SizePx*diamondHalfPerSize)) + 1
		center := image.Pt(int(o.X), int(o.Y))
		bounds := image.Rectangle{Min: center.Sub(image.Pt(reach, reach)), Max: center.Add(image.Pt(reach, reach))}
		fill(canvas, bounds.Intersect(canvas.Rect), shapeColors[o.ColorID], shapeInside(o))
		plateDraw(canvas, o)
	}
	var out bytes.Buffer
	encoder := png.Encoder{CompressionLevel: png.BestSpeed}
	if err := encoder.Encode(&out, canvas); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}
