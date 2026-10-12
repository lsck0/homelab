package main

import (
	"cmp"
	"fmt"
	"math"
	"math/rand/v2"
	"slices"
	"strings"
)

/*
 * -----------------------------------------------------------------------------
 * CONSTANTS
 * -----------------------------------------------------------------------------
 */

// The scene: objects in distinct cells of a grid, each a shape with a label plate below it. The cells keep a shape and
// its plate apart from every other; the jitter keeps the scene from being a readable table.
const (
	// portrait, so a phone shows it whole with the labels' glyphs still 14 px tall
	canvasWidthPx  = 540
	canvasHeightPx = 600
	gridColumns    = 3
	gridRows       = 4
	objectCount    = 7
	cellWidthPx    = canvasWidthPx / gridColumns
	cellHeightPx   = canvasHeightPx / gridRows
	// a shape's circumradius; the largest shape and its plate fill a cell's height
	sizeMinPx = 16
	sizeMaxPx = 42
	// a center moves this far from its cell's middle, so neighbours never touch
	jitterPx = 14
	// above the tallest shape of a row; its plate still ends inside the cell
	topPaddingPx = 6
)

// What makes a question unambiguous to a person: positions an ordinal compares differ by this much, a size called the
// largest or smallest beats the runner-up by this ratio, the nearest shape is this much nearer than the second.
const (
	ordinalGapMinPx  = 60
	sizeRatioMin     = 1.3
	nearestRatioMin  = 1.35
	labelBytes       = 3
	labelChars       = 2 * labelBytes
	labelMutations   = 2
	sceneAttemptsMax = 64
	// one question in this many asks for the label backwards
	backwardsOneIn = 3
)

/*
 * -----------------------------------------------------------------------------
 * TYPES
 * -----------------------------------------------------------------------------
 */

// Shape is what an object looks like; the question names it, never its color.
type Shape int

const (
	ShapeCircle Shape = iota
	ShapeSquare
	ShapeTriangle
	ShapeDiamond
	ShapeCount
)

var shapeNames = [ShapeCount]string{"circle", "square", "triangle", "diamond"}

// Object is one labelled shape of the scene, its center and circumradius in pixels.
type Object struct {
	Shape   Shape
	X, Y    float64
	SizePx  float64
	Label   string
	ColorID int
}

// Puzzle is one generated scene, its question and the answer, all from one seed.
type Puzzle struct {
	Objects  []Object
	Question string
	Answer   string
}

/*
 * -----------------------------------------------------------------------------
 * INTERNAL
 * -----------------------------------------------------------------------------
 */

var ordinalNames = []string{"first", "second", "third", "fourth", "fifth", "sixth", "seventh"}

// labelsGenerate makes labels that differ from a base in a few characters each: a misread or a confused neighbour
// yields a plausible wrong label, never a near miss that happens to be right.
func labelsGenerate(rng *rand.Rand) []string {
	const hexDigits = "0123456789abcdef"
	base := make([]byte, labelChars)
	for i := range base {
		base[i] = hexDigits[rng.IntN(len(hexDigits))]
	}
	labels := make([]string, 0, objectCount)
	seen := map[string]bool{}
	for len(labels) < objectCount {
		label := slices.Clone(base)
		for range labelMutations {
			label[rng.IntN(labelChars)] = hexDigits[rng.IntN(len(hexDigits))]
		}
		text := string(label)
		reversed := labelReverse(text)
		// a label must not be another's reversal: "backwards" questions would have two answers on the plates
		if seen[text] || seen[reversed] || text == reversed {
			continue
		}
		seen[text] = true
		labels = append(labels, text)
	}
	return labels
}

func labelReverse(label string) string {
	runes := []rune(label)
	slices.Reverse(runes)
	return string(runes)
}

func sceneGenerate(rng *rand.Rand, colorCount int) []Object {
	cells := rng.Perm(gridColumns * gridRows)[:objectCount]
	labels := labelsGenerate(rng)
	objects := make([]Object, objectCount)
	for i, cell := range cells {
		column, row := cell%gridColumns, cell/gridColumns
		size := sizeMinPx + rng.Float64()*(sizeMaxPx-sizeMinPx)
		objects[i] = Object{
			Shape:  Shape(rng.IntN(int(ShapeCount))),
			X:      float64(column*cellWidthPx+cellWidthPx/2) + (rng.Float64()*2-1)*jitterPx,
			Y:      float64(row*cellHeightPx) + topPaddingPx + sizeMaxPx + (rng.Float64()*2-1)*jitterPx/2,
			SizePx: size,
			Label:  labels[i],
			// neighbours by index may share a color; the question never names one
			ColorID: rng.IntN(colorCount),
		}
	}
	return objects
}

func objectsOfShape(objects []Object, shape Shape) []int {
	var indices []int
	for i, object := range objects {
		if object.Shape == shape {
			indices = append(indices, i)
		}
	}
	return indices
}

// candidate is one well-posed question: its wording and the object whose label answers it.
type candidate struct {
	text   string
	answer int
}

func candidatesOrdinal(objects []Object, shape Shape) []candidate {
	indices := objectsOfShape(objects, shape)
	if len(indices) < 2 {
		return nil
	}
	var out []candidate
	for _, axis := range []struct {
		from string
		pos  func(Object) float64
	}{
		{"left", func(o Object) float64 { return o.X }},
		{"top", func(o Object) float64 { return o.Y }},
	} {
		sorted := slices.Clone(indices)
		slices.SortFunc(sorted, func(a, b int) int { return cmp.Compare(axis.pos(objects[a]), axis.pos(objects[b])) })
		separated := true
		for i := 1; i < len(sorted); i++ {
			if axis.pos(objects[sorted[i]])-axis.pos(objects[sorted[i-1]]) < ordinalGapMinPx {
				separated = false
			}
		}
		if !separated {
			continue
		}
		for rank, index := range sorted {
			out = append(out, candidate{
				text:   fmt.Sprintf("Counting the %ss from the %s, which label does the %s one carry?", shapeNames[shape], axis.from, ordinalNames[rank]),
				answer: index,
			})
		}
	}
	return out
}

// anchorsUnique are the objects a phrase names unambiguously: the only one of a shape, a clearly largest or smallest one.
func anchorsUnique(objects []Object) []candidate {
	var out []candidate
	for shape := range ShapeCount {
		indices := objectsOfShape(objects, shape)
		switch {
		case len(indices) == 1:
			out = append(out, candidate{text: "the only " + shapeNames[shape], answer: indices[0]})
		case len(indices) >= 2:
			sorted := slices.Clone(indices)
			slices.SortFunc(sorted, func(a, b int) int { return cmp.Compare(objects[b].SizePx, objects[a].SizePx) })
			last := len(sorted) - 1
			if objects[sorted[0]].SizePx >= sizeRatioMin*objects[sorted[1]].SizePx {
				out = append(out, candidate{text: "the largest " + shapeNames[shape], answer: sorted[0]})
			}
			if objects[sorted[last-1]].SizePx >= sizeRatioMin*objects[sorted[last]].SizePx {
				out = append(out, candidate{text: "the smallest " + shapeNames[shape], answer: sorted[last]})
			}
		}
	}
	return out
}

func candidatesNearest(objects []Object, anchor candidate) []candidate {
	from := objects[anchor.answer]
	nearest, second := -1, math.Inf(1)
	nearestDistance := math.Inf(1)
	for i, object := range objects {
		if i == anchor.answer {
			continue
		}
		distance := math.Hypot(object.X-from.X, object.Y-from.Y)
		switch {
		case distance < nearestDistance:
			second, nearestDistance, nearest = nearestDistance, distance, i
		case distance < second:
			second = distance
		}
	}
	if nearest < 0 || second < nearestRatioMin*nearestDistance {
		return nil
	}
	return []candidate{{text: "Which label belongs to the shape nearest to " + anchor.text + "?", answer: nearest}}
}

func candidatesAll(objects []Object) []candidate {
	var out []candidate
	for shape := range ShapeCount {
		out = append(out, candidatesOrdinal(objects, shape)...)
	}
	for _, anchor := range anchorsUnique(objects) {
		if !strings.HasPrefix(anchor.text, "the only") {
			out = append(out, candidate{text: "Which label belongs to " + anchor.text + "?", answer: anchor.answer})
		}
		out = append(out, candidatesNearest(objects, anchor)...)
	}
	return out
}

/*
 * -----------------------------------------------------------------------------
 * FUNCTIONS
 * -----------------------------------------------------------------------------
 */

// puzzleFromSeed generates the scene, the question and its answer; the same seed always yields the same puzzle, so
// the gate keeps only the seed and the answer never leaves the server.
func puzzleFromSeed(seed uint64, colorCount int) Puzzle {
	rng := rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15)) // the golden ratio's bits: any fixed odd stream works
	for range sceneAttemptsMax {
		objects := sceneGenerate(rng, colorCount)
		candidates := candidatesAll(objects)
		if len(candidates) == 0 {
			continue
		}
		chosen := candidates[rng.IntN(len(candidates))]
		answer := objects[chosen.answer].Label
		question := chosen.text
		if rng.IntN(backwardsOneIn) == 0 {
			answer = labelReverse(answer)
			question += " Type that label backwards, last character first."
		}
		return Puzzle{Objects: objects, Question: question, Answer: answer}
	}
	// a scene of seven objects has a well-posed question almost always; puzzle_test.go proves the bound over seeds
	panic(fmt.Sprintf("puzzle: no question in %d scenes of seed %d", sceneAttemptsMax, seed))
}

// answerNormalize parses what a person typed: six hex digits, any case, an optional 0x, surrounding spaces.
func answerNormalize(typed string) (string, bool) {
	text := strings.ToLower(strings.TrimSpace(typed))
	text = strings.TrimPrefix(text, "0x")
	if len(text) != labelChars {
		return "", false
	}
	for _, c := range text {
		if !strings.ContainsRune("0123456789abcdef", c) {
			return "", false
		}
	}
	return text, true
}
