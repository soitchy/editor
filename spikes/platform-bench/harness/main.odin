// Spawns a spike N times and reports, per stage, milliseconds since spawn.
// Spikes print `MARK <label> <unix_ns>`; spawn time is taken from the same
// wall clock just before process start, so the numbers include exec and
// dynamic linking, which is what "cold start" means to a user.
//
//   harness gen <path> <mb>                         write a test text file
//   harness run [--runs N] -- <exe> [spike args]    time a spike
package harness

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

Sample :: struct {
	label: string,
	ms:    f64,
}

main :: proc() {
	if len(os.args) < 2 do usage()
	switch os.args[1] {
	case "gen": gen()
	case "run": run()
	case: usage()
	}
}

usage :: proc() {
	fmt.eprintln("usage: harness gen <path> <mb> | harness run [--runs N] -- <exe> [args]")
	os.exit(2)
}

// Source-code-shaped lines of varying length, so line counts are realistic
// (~2.5M lines per 100MB) rather than one giant line.
gen :: proc() {
	if len(os.args) < 4 do usage()
	path := os.args[2]
	mb, _ := strconv.parse_int(os.args[3])
	lines := [?]string{
		"package main",
		"",
		"import \"core:fmt\"",
		"// The quick brown fox jumps over the lazy dog, again and again and again.",
		"buffer_insert :: proc(b: ^Buffer, at: int, text: string) -> (ok: bool) {",
		"\tpiece := Piece{source = .Add, start = len(b.add), length = len(text)}",
		"\tappend(&b.add, ..transmute([]u8)text)",
		"\treturn tree_insert(&b.tree, at, piece)",
		"}",
		"\tfor sel, i in selections { fmt.printfln(\"%d: %v..%v\", i, sel.anchor, sel.head) }",
	}
	sb := strings.builder_make()
	target := mb * 1024 * 1024
	n := 0
	for strings.builder_len(sb) < target {
		fmt.sbprintfln(&sb, "%s", lines[n % len(lines)])
		n += 1
	}
	if err := os.write_entire_file(path, sb.buf[:]); err != nil {
		fmt.eprintln("gen:", err)
		os.exit(1)
	}
	fmt.printfln("wrote %s: %d bytes, %d lines", path, strings.builder_len(sb), n)
}

run :: proc() {
	runs := 10
	cmd_start := -1
	for i := 2; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--runs":
			i += 1
			runs, _ = strconv.parse_int(os.args[i])
		case "--":
			cmd_start = i + 1
		}
		if cmd_start >= 0 do break
	}
	if cmd_start < 0 || cmd_start >= len(os.args) do usage()
	cmd := os.args[cmd_start:]

	order: [dynamic]string
	per_label := make(map[string][dynamic]f64)
	first: [dynamic]Sample
	infos: [dynamic]string

	for r in 0 ..< runs {
		t0 := time.to_unix_nanoseconds(time.now())
		state, stdout, stderr, err := os.process_exec({command = cmd}, context.allocator)
		if err != nil || !state.success {
			fmt.eprintfln("run %d failed: %v exit=%d\n%s", r, err, state.exit_code, string(stderr))
			os.exit(1)
		}
		text := string(stdout)
		for line in strings.split_lines_iterator(&text) {
			parts := strings.fields(line)
			if len(parts) >= 3 && parts[0] == "MARK" {
				ns, _ := strconv.parse_i64(parts[2])
				ms := f64(ns - t0) / 1e6
				if parts[1] not_in per_label {
					append(&order, parts[1])
					per_label[parts[1]] = {}
				}
				append(&per_label[parts[1]], ms)
				if r == 0 do append(&first, Sample{parts[1], ms})
			} else if r == 0 && len(parts) >= 3 && parts[0] == "INFO" {
				append(&infos, strings.join(parts[1:], " "))
			}
		}
		time.sleep(200 * time.Millisecond) // let the window server settle between runs
	}

	fmt.printfln("cmd: %s", strings.join(cmd, " "))
	for i in infos do fmt.printfln("info: %s", i)
	fmt.printfln("runs: %d (ms since spawn; first run listed separately)", runs)
	fmt.printfln("%-12s %8s %8s %8s %8s", "stage", "first", "median", "min", "max")
	for label, i in order {
		xs := per_label[label][:]
		slice.sort(xs)
		// Odin's fmt zero-pads widened floats, so format each number first.
		f :: proc(ms: f64) -> string { return fmt.tprintf("%.1f", ms) }
		fmt.printfln("%-12s %8s %8s %8s %8s", label, f(first[i].ms), f(xs[len(xs) / 2]), f(xs[0]), f(xs[len(xs) - 1]))
	}
}
