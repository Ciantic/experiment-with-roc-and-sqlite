## An in-memory SQLite database of widgets: create a table, insert rows,
## query them back as Roc records, then update and re-query.
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-29-a0a9fc2",
}

import cli.Sqlite
import cli.Sqlite.Decoder
import cli.Stdout

# A row of the `widgets` table.
Widget : {
	id : I64,
	name : Str,
	kind : Kind,
	weight : F64,
}

# Stored in SQLite as TEXT; `kind_from_str` rejects anything else.
Kind : [Gear, Sprocket, Spring, Bolt]

# A widget before SQLite has assigned it an id.
NewWidget : { name : Str, kind : Kind, weight : F64 }

main! = |_| {
	# `":memory:"` is a private database, visible only to this connection and
	# gone once it is released.
	db = Sqlite.open_in_memory!()?

	db.execute!(
		"CREATE TABLE widgets (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kind TEXT NOT NULL, weight REAL NOT NULL)",
	)?

	seeded = [
		{ name: "Cog", kind: Gear, weight: 12.5 },
		{ name: "Ratchet", kind: Sprocket, weight: 3.25 },
		{ name: "Helix", kind: Spring, weight: 0.75 },
		{ name: "M8 hex", kind: Bolt, weight: 0.05 },
		{ name: "Pinion", kind: Gear, weight: 8.0 },
	]

	# One transaction for all inserts: either every widget is stored, or none.
	db.transaction!(
		|| {
			for widget in seeded {
				insert_widget!(db, widget)?
			}
			Ok({})
		},
	)?

	Stdout.line!("Inserted ${count_widgets!(db)?.to_str()} widgets into an in-memory database.")?
	Stdout.line!("")?

	Stdout.line!("All widgets:")?
	print_widgets!(all_widgets!(db)?)?

	Stdout.line!("")?
	Stdout.line!("Gears only:")?
	print_widgets!(widgets_of_kind!(db, Gear)?)?

	total = total_weight!(db)?
	heaviest = heaviest_widget!(db)?
	Stdout.line!("")?
	Stdout.line!("Total weight: ${total.to_str()} g")?
	Stdout.line!("Heaviest: ${heaviest.name} (${heaviest.weight.to_str()} g)")?

	# Values in `${…}` are bound as statement parameters, never pasted into the
	# SQL text, so they need no quoting or escaping.
	db.execute!("UPDATE widgets SET weight = ${Real(20.0)} WHERE name = ${String("Pinion")}")?

	updated = heaviest_widget!(db)?
	Stdout.line!("")?
	Stdout.line!("After updating Pinion: heaviest is ${updated.name} (${updated.weight.to_str()} g)")?

	Ok({})
}

insert_widget! : Sqlite.Db, NewWidget => Try({}, _)
insert_widget! = |db, widget|
	db.execute!(
		"INSERT INTO widgets (name, kind, weight) VALUES (${String(widget.name)}, ${String(kind_to_str(widget.kind))}, ${Real(widget.weight)})",
	)

count_widgets! : Sqlite.Db => Try(I64, _)
count_widgets! = |db|
	db.query_one!("SELECT COUNT(*) FROM widgets", Decoder.i64(0))

all_widgets! : Sqlite.Db => Try(List(Widget), _)
all_widgets! = |db|
	db.query_all!("SELECT id, name, kind, weight FROM widgets ORDER BY id", decode_widget)

widgets_of_kind! : Sqlite.Db, Kind => Try(List(Widget), _)
widgets_of_kind! = |db, kind|
	db.query_all!(
		"SELECT id, name, kind, weight FROM widgets WHERE kind = ${String(kind_to_str(kind))} ORDER BY name",
		decode_widget,
	)

total_weight! : Sqlite.Db => Try(F64, _)
total_weight! = |db|
	db.query_one!("SELECT SUM(weight) FROM widgets", Decoder.f64(0))

heaviest_widget! : Sqlite.Db => Try(Widget, _)
heaviest_widget! = |db|
	db.query_one!("SELECT id, name, kind, weight FROM widgets ORDER BY weight DESC, id LIMIT 1", decode_widget)

# A row decoder is a record of column decoders; the `.Decoder` suffix turns it
# into a decoder of records. Columns are named, or addressed by position (0 is
# the first), as `Decoder.i64(0)` does above.
decode_widget : Decoder(Widget, _)
decode_widget = {
	id: Decoder.i64("id"),
	name: Decoder.str("name"),
	kind: Decoder.str("kind").map_try(kind_from_str),
	weight: Decoder.f64("weight"),
}.Decoder

kind_to_str : Kind -> Str
kind_to_str = |kind|
	match kind {
		Gear => "gear"
		Sprocket => "sprocket"
		Spring => "spring"
		Bolt => "bolt"
	}

kind_from_str : Str -> Try(Kind, [UnknownKind(Str)])
kind_from_str = |kind|
	match kind {
		"gear" => Ok(Gear)
		"sprocket" => Ok(Sprocket)
		"spring" => Ok(Spring)
		"bolt" => Ok(Bolt)
		other => Err(UnknownKind(other))
	}

print_widgets! : List(Widget) => Try({}, _)
print_widgets! = |widgets| {
	for widget in widgets {
		Stdout.line!("    #${widget.id.to_str()}  ${widget.name} (${kind_to_str(widget.kind)}, ${widget.weight.to_str()} g)")?
	}
	Ok({})
}
