## An in-memory SQLite database with two related tables, `invoices` and
## `invoice_rows`. `query_invoice!` and `query_invoice_row!` take a Projection —
## a record of typed columns — and select exactly those columns, so each query
## is a record shape and nothing else.
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

# A decoder paired with the columns it reads. `Sqlite.Decoder` is opaque, so
# its own column list cannot drive the SQL; this keeps a visible copy alongside
# it, built by the same call.
Projection(a, err) := { columns : List(Str), decoder : Decoder(a, err) }.{
	# What the record-builder suffix calls: `{ number, status }.Projection`
	# folds a record of projections into one projection of a record, combining
	# each pair with this function.
	map2 : Projection(a, err), Projection(b, err), (a, b -> c) -> Projection(c, err)
	map2 = |first, second, combine|
		Projection.{
			columns: first.columns.concat(second.columns),
			decoder: Decoder.map2(first.decoder, second.decoder, combine),
		}

	# One column, from any leaf decoder.
	field : Str, (Sqlite.Column -> Decoder(a, err)) -> Projection(a, err)
	field = |name, make| {
		column = Sqlite.Column.from_quote(name) ?? crash "a column name is a plain Str"
		Projection.{ columns: [name], decoder: make(column) }
	}

	str : Str -> Projection(Str, _)
	str = |name| field(name, Decoder.str)

	i64 : Str -> Projection(I64, _)
	i64 = |name| field(name, Decoder.i64)

	# Accept SQL `NULL`, decoding to `Err(Null)` when the column is NULL.
	nullable : Projection(a, err) -> Projection(Try(a, [Null]), err)
	nullable = |projection|
		Projection.{
			columns: projection.columns,
			decoder: projection.decoder.nullable(),
		}

	# Transform the decoded value with a function that can fail.
	map_try : Projection(a, err), (a -> Try(b, err)) -> Projection(b, err)
	map_try = |projection, transform|
		Projection.{
			columns: projection.columns,
			decoder: projection.decoder.map_try(transform),
		}
}

# Each column is typed once, here, and named after its field, so a projection
# is a record of puns: `{ number, status }.Projection`.
#
# They sit above `main!` because a punned record literal inside a function body
# does not see top-level definitions declared later in the file (a limitation of
# this nightly); ordinary name references are order-independent.
id : Projection(I64, _)
id = Projection.i64("id")

number : Projection(Str, _)
number = Projection.str("number")

customer : Projection(Str, _)
customer = Projection.str("customer")

status : Projection(Status, _)
status = Projection.str("status").map_try(status_from_str)

paid_on : Projection(Try(Str, [Null]), _)
paid_on = Projection.nullable(Projection.str("paid_on"))

row_id : Projection(I64, _)
row_id = Projection.i64("id")

invoice_id : Projection(I64, _)
invoice_id = Projection.i64("invoice_id")

description : Projection(Str, _)
description = Projection.str("description")

quantity : Projection(I64, _)
quantity = Projection.i64("quantity")

unit_cents : Projection(I64, _)
unit_cents = Projection.i64("unit_cents")

# Every column of each table, in field order.
invoice_projection : Projection(Invoice, _)
invoice_projection = { id, number, customer, status, paid_on }.Projection

invoice_row_projection : Projection(InvoiceRow, _)
invoice_row_projection = { row_id, invoice_id, description, quantity, unit_cents }.Projection

# The SQL names exactly the columns the projection carries.
quote_column : Str -> Str
quote_column = |name| "\"${name}\""

table_query : Str, List(Str) -> Sqlite.Query
table_query = |table, columns|
	Sqlite.Query.new(
		"SELECT ${Str.join_with(columns.map(quote_column), ", ")} FROM ${table} ORDER BY id",
		[],
	)

query_invoice! : Sqlite.Db, Projection(a, _) => Try(List(a), _)
query_invoice! = |db, projection|
	db.query_all!(table_query("invoices", projection.columns), projection.decoder)

query_invoice_row! : Sqlite.Db, Projection(a, _) => Try(List(a), _)
query_invoice_row! = |db, projection|
	db.query_all!(table_query("invoice_rows", projection.columns), projection.decoder)

main! = |_| {
	db = Sqlite.open_in_memory!()?
	setup!(db)?

	Stdout.line!("Invoices, id and number:")?
	for invoice in query_invoice!(db, { id, number }.Projection)? {
		Stdout.line!("  #${invoice.id.to_str()}  ${invoice.number}")?
	}

	Stdout.line!("")?
	Stdout.line!("Invoices, number and status:")?
	for invoice in query_invoice!(db, { number, status }.Projection)? {
		Stdout.line!("  ${invoice.number}  ${status_to_str(invoice.status)}")?
	}

	Stdout.line!("")?
	Stdout.line!("Invoices, every column:")?
	for invoice in query_invoice!(db, invoice_projection)? {
		paid = match invoice.paid_on {
			Ok(date) => "paid ${date}"
			Err(Null) => "open"
		}
		Stdout.line!("  #${invoice.id.to_str()}  ${invoice.number}  ${invoice.customer}  ${status_to_str(invoice.status)}  (${paid})")?
	}

	Stdout.line!("")?
	Stdout.line!("Invoice rows, description and quantity:")?
	for row in query_invoice_row!(db, { description, quantity }.Projection)? {
		Stdout.line!("  ${row.description}  ${row.quantity.to_str()}")?
	}

	Stdout.line!("")?
	Stdout.line!("Invoice rows, every column:")?
	for row in query_invoice_row!(db, invoice_row_projection)? {
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
	frac_str = if frac < 10 { "0${frac.to_str()}" } else { frac.to_str() }
	"${whole.to_str()}.${frac_str}"
}
