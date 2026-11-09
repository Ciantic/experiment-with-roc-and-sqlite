## An in-memory SQLite database with two related tables, `invoices` and
## `invoice_rows`. A `Table` is a record of typed columns bound to a table, so
## `query!` selects exactly those columns and each query is a record shape.
## Each column constant carries its table as a phantom type tag, so mixing
## columns from two tables — `{ id, unit_cents }.Projection` — is a type error
## rather than a runtime surprise.
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-29-a0a9fc2",
}

import cli.Sqlite
import cli.Sqlite.Decoder
import cli.Stdout

# A row of `invoices`. `paid_on` is NULL until the invoice is paid, so it
# decodes to `Ok(date)` or `Err(Null)`.
Invoice : {
	id : I64,
	number : Str,
	customer : Str,
	status : Status,
	paid_on : Try(Str, [Null]),
}

# A row of `invoice_rows`. `row_id` decodes the table's `id` column: the name
# keeps it distinct from the `id` constant used for `invoices`.
InvoiceRow : {
	row_id : I64,
	invoice_id : I64,
	description : Str,
	quantity : I64,
	unit_cents : I64,
}

# Stored in SQLite as TEXT; `status_from_str` rejects anything else.
Status : [Draft, Sent, Paid]

# Phantom table tags: never constructed, only used as a type parameter. Two
# nominal types never unify, so a `Projection(Invoices, …)` and a
# `Projection(InvoiceRows, …)` cannot be combined.
#
# The diagnostics come from the fold: mixing tables makes `map2` fail to unify
# its two `Projection(t, …)` parameters, so the error points at the record
# literal's `.Projection` and reads as a type mismatch between the two columns.
# That is the compile-time check working — it just does not phrase itself as
# "unit_cents is not an invoices column".
Invoices := {}

InvoiceRows := {}

# A decoder paired with the columns it reads. `Sqlite.Decoder` is opaque, so
# its own column list cannot drive the SQL; this keeps a visible copy alongside
# it, built by the same call.
Projection(table, a, err) := { columns : List(Str), decoder : Decoder(a, err) }.{
	# What the record-builder suffix calls: `{ number, status }.Projection`
	# folds a record of projections into one projection of a record, combining
	# each pair with this function.
	#
	# The suffix is the fold, not decoration: `{ number, id }` on its own is a
	# record of two Projections, and it stays one. Roc has no way to walk a
	# record's fields, so no function can fold an arbitrary record of columns
	# for you — the compiler applies `map2` per field only where the suffix is
	# written. That is why every query spells `.Projection`, and why a
	# single-column record cannot be folded at all.
	# Both sides must name the same table, and so must their error rows: mixing
	# an `invoices` column with an `invoice_rows` one fails to typecheck here.
	map2 : Projection(t, a, err), Projection(t, b, err), (a, b -> c) -> Projection(t, c, err)
	map2 = |first, second, combine|
		Projection.{
			columns: first.columns.concat(second.columns),
			decoder: Decoder.map2(first.decoder, second.decoder, combine),
		}

	# One column, from any leaf decoder.
	field : Str, (Sqlite.Column -> Decoder(a, err)) -> Projection(t, a, err)
	field = |name, make| {
		column = Sqlite.Column.from_quote(name) ?? crash "a column name is a plain Str"
		Projection.{ columns: [name], decoder: make(column) }
	}

	str : Str -> Projection(t, Str, _)
	str = |name| field(name, Decoder.str)

	i64 : Str -> Projection(t, I64, _)
	i64 = |name| field(name, Decoder.i64)

	# Accept SQL `NULL`, decoding to `Err(Null)` when the column is NULL.
	nullable : Projection(t, a, err) -> Projection(t, Try(a, [Null]), err)
	nullable = |projection|
		Projection.{
			columns: projection.columns,
			decoder: projection.decoder.nullable(),
		}

	# Transform the decoded value with a function that can fail.
	map_try : Projection(t, a, err), (a -> Try(b, err)) -> Projection(t, b, err)
	map_try = |projection, transform|
		Projection.{
			columns: projection.columns,
			decoder: projection.decoder.map_try(transform),
		}

	# The columns this projection reads, for building SQL or for tests.
	to_columns : Projection(t, a, err) -> List(Str)
	to_columns = |projection| projection.columns
}

# A projection bound to a table: the columns, their decoder, and where they
# live. Binding the name here is what lets the same projection be queried, and
# lets `subset` name the table it checked against.
Table(table, a, err) := { name : Str, columns : List(Str), decoder : Decoder(a, err) }.{
	from_projection : Str, Projection(table, a, err) -> Table(table, a, err)
	from_projection = |name, projection|
		Table.{ name, columns: projection.columns, decoder: projection.decoder }

	# Narrow a table projection to the columns picked from it.
	#
	# The type parameter already guarantees the picked columns come from this
	# table: `Projection(t, …)` unifies only with columns built for the same
	# tag, so a cross-table pick is a compile error before `subset` is reached.
	# The loop below is the remaining runtime guard: a column constant whose
	# name is not in this table's projection (a typo in `Projection.str`) would
	# otherwise produce SQL selecting a name the table may not have.
	subset : Table(t, a, err), Projection(t, b, err) -> Table(t, b, err)
	subset = |table, picked| {
		for name in picked.columns {
			if !List.contains(table.columns, name) {
				crash "not a column of ${table.name}: ${Str.inspect(name)}"
			}
		}
		Table.{ name: table.name, columns: picked.columns, decoder: picked.decoder }
	}

	# The statement this table projection runs.
	to_sql : Table(t, a, err) -> Str
	to_sql = |table|
		"SELECT ${Str.join_with(table.columns.map(quote_column), ", ")} FROM ${table.name} ORDER BY id"

	# Run it: the columns become the SELECT list, the decoders read the rows.
	query! : Table(t, a, err), Sqlite.Db => Try(List(a), _)
	query! = |table, db| {
		db.query_all!(Sqlite.Query.new(table.to_sql(), []), table.decoder)
	}
}

# Each column is typed once, here, and named after its field, so a projection
# is a record of puns: `{ number, status }.Projection`.
#
# They sit above `main!` because a punned record literal inside a function body
# does not see top-level definitions declared later in the file (a limitation of
# this nightly); ordinary name references are order-independent.
id : Projection(Invoices, I64, _)
id = Projection.i64("id")

number : Projection(Invoices, Str, _)
number = Projection.str("number")

customer : Projection(Invoices, Str, _)
customer = Projection.str("customer")

status : Projection(Invoices, Status, _)
status = Projection.str("status").map_try(status_from_str)

paid_on : Projection(Invoices, Try(Str, [Null]), _)
paid_on = Projection.nullable(Projection.str("paid_on"))

row_id : Projection(InvoiceRows, I64, _)
row_id = Projection.i64("id")

invoice_id : Projection(InvoiceRows, I64, _)
invoice_id = Projection.i64("invoice_id")

description : Projection(InvoiceRows, Str, _)
description = Projection.str("description")

quantity : Projection(InvoiceRows, I64, _)
quantity = Projection.i64("quantity")

unit_cents : Projection(InvoiceRows, I64, _)
unit_cents = Projection.i64("unit_cents")

# Every column of each table, in field order.
#
# The record literal is the single source of truth: its fields supply the field
# names as puns, and the builder turns them into the SQL column list and the
# decoders into a record decoder. The type is then inferred from the literal and
# is exactly `Invoice`, which is why the annotations here only document it —
# deleting them still compiles. The derivation runs literal -> columns + decoder
# -> type, never type -> columns: Roc has no type reflection, and compile-time
# evaluation folds pure expressions rather than inspecting types, so nothing in
# the language turns `Invoice` into `["id", "number", …]`. Each column constant
# above exists because a field's type has to be stated once (`str` vs `i64`), and
# that cannot be read back off the record type.
# The SQL table name lives here, once per tag.
invoice_table : Projection(Invoices, a, err) -> Table(Invoices, a, err)
invoice_table = |projection| Table.from_projection("invoices", projection)

invoice_row_table : Projection(InvoiceRows, a, err) -> Table(InvoiceRows, a, err)
invoice_row_table = |projection| Table.from_projection("invoice_rows", projection)

invoice_projection : Table(Invoices, Invoice, _)
invoice_projection = invoice_table({ id, number, customer, status, paid_on }.Projection)

invoice_row_projection : Table(InvoiceRows, InvoiceRow, _)
invoice_row_projection = invoice_row_table({ row_id, invoice_id, description, quantity, unit_cents }.Projection)

# The SQL names exactly the columns the projection carries.
quote_column : Str -> Str
quote_column = |name| "\"${name}\""

main! = |_| {
	db = Sqlite.open_in_memory!()?
	setup!(db)?

	Stdout.line!("Invoices, id and number (subset of the table projection):")?
	for invoice in invoice_projection.subset({ id, number }.Projection).query!(db)? {
		Stdout.line!("  #${invoice.id.to_str()}  ${invoice.number}")?
	}

	Stdout.line!("")?
	Stdout.line!("Invoices, number and status:")?
	for invoice in invoice_projection.subset({ number, status }.Projection).query!(db)? {
		Stdout.line!("  ${invoice.number}  ${status_to_str(invoice.status)}")?
	}

	Stdout.line!("")?
	Stdout.line!("Invoices, every column:")?
	for invoice in invoice_projection.query!(db)? {
		paid = match invoice.paid_on {
			Ok(date) => "paid ${date}"
			Err(Null) => "open"
		}
		Stdout.line!("  #${invoice.id.to_str()}  ${invoice.number}  ${invoice.customer}  ${status_to_str(invoice.status)}  (${paid})")?
	}

	Stdout.line!("")?
	Stdout.line!("Invoice rows, description and quantity (subset of the row table):")?
	for row in invoice_row_projection.subset({ description, quantity }.Projection).query!(db)? {
		Stdout.line!("  ${row.description}  ${row.quantity.to_str()}")?
	}

	Stdout.line!("")?
	Stdout.line!("Invoice rows, every column:")?
	for row in invoice_row_projection.query!(db)? {
		Stdout.line!(
			"  row #${row.row_id.to_str()}  invoice ${row.invoice_id.to_str()}  ${row.description}  ${row.quantity.to_str()} x ${format_cents(row.unit_cents)}",
		)?
	}

	Ok({})
}

setup! : Sqlite.Db => Try({}, _)
setup! = |db| {
	db.execute!("PRAGMA foreign_keys = ON")?
	db.execute!(
		"CREATE TABLE invoices (id INTEGER PRIMARY KEY, number TEXT NOT NULL UNIQUE, customer TEXT NOT NULL, status TEXT NOT NULL, paid_on TEXT)",
	)?
	db.execute!(
		"CREATE TABLE invoice_rows (id INTEGER PRIMARY KEY, invoice_id INTEGER NOT NULL REFERENCES invoices(id) ON DELETE CASCADE, description TEXT NOT NULL, quantity INTEGER NOT NULL, unit_cents INTEGER NOT NULL)",
	)?
	db.execute!(
		"INSERT INTO invoices (id, number, customer, status, paid_on) VALUES (1, 'INV-2026-001', 'Acme Ltd', 'sent', NULL), (2, 'INV-2026-002', 'Globex', 'paid', '2026-10-20'), (3, 'INV-2026-003', 'Initech', 'draft', NULL)",
	)?
	db.execute!(
		"INSERT INTO invoice_rows (id, invoice_id, description, quantity, unit_cents) VALUES (1, 1, 'Consulting', 12, 9500), (2, 1, 'Hosting', 1, 12900), (3, 2, 'Support retainer', 3, 45000), (4, 3, 'Design sprint', 1, 240000)",
	)?
	Ok({})
}

status_to_str : Status -> Str
status_to_str = |s|
	match s {
		Draft => "draft"
		Sent => "sent"
		Paid => "paid"
	}

status_from_str : Str -> Try(Status, [UnknownStatus(Str)])
status_from_str = |text|
	match text {
		"draft" => Ok(Draft)
		"sent" => Ok(Sent)
		"paid" => Ok(Paid)
		other => Err(UnknownStatus(other))
	}

format_cents : I64 -> Str
format_cents = |cents| {
	whole = cents // 100
	frac = cents % 100
	frac_str = if frac < 10 {
		"0${frac.to_str()}"
	} else {
		frac.to_str()
	}
	"${whole.to_str()}.${frac_str}"
}
