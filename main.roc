## An in-memory SQLite database with two related tables, `invoices` and
## `invoice_rows`. A `Table` is a record of typed columns bound to a table, so
## `query!` selects exactly those columns and each query is a record shape;
## `filter_in` adds bound `WHERE ... IN (...)` terms, in any order relative to
## `select`.
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

# One `WHERE` term: SQL with `?` markers, and the values for them.
no_filters : List(Filter)
no_filters = []

# A projection bound to a table: the columns, their decoder, where they live,
# and any filters to apply. Binding the name here is what lets the same
# projection be queried, and lets `select` name the table it checked against.
Table(table, a, err) := {
	name : Str,
	columns : List(Str),
	decoder : Decoder(a, err),
	filters : List(Filter),
}.{
	from_projection : Str, Projection(table, a, err) -> Table(table, a, err)
	from_projection = |name, projection|
		Table.{
			name,
			columns: projection.columns,
			decoder: projection.decoder,
			filters: no_filters,
		}

	# Narrow a table projection to the columns picked from it.
	#
	# The type parameter already guarantees the picked columns come from this
	# table: `Projection(t, …)` unifies only with columns built for the same
	# tag, so a cross-table pick is a compile error before `select` is reached.
	# The loop below is the remaining runtime guard: a column constant whose
	# name is not in this table's projection (a typo in `Projection.str`) would
	# otherwise produce SQL selecting a name the table may not have.
	select : Table(t, a, err), Projection(t, b, err) -> Table(t, b, err)
	select = |table, picked| {
		for name in picked.columns {
			if !List.contains(table.columns, name) {
				crash "not a column of ${table.name}: ${Str.inspect(name)}"
			}
		}
		Table.{
			name: table.name,
			columns: picked.columns,
			decoder: picked.decoder,
			filters: table.filters,
		}
	}

	# Keep the rows whose column is one of `values`, as SQL `IN`.
	#
	# The tag on `column` makes a foreign column a type error even here, after
	# `select` has narrowed the output columns: the filter is part of the
	# `WHERE` clause, not of the `SELECT` list, so it may name any column of
	# the table. An empty list matches nothing, which is what `IN ()` would
	# mean if SQLite accepted it.
	filter_in : Table(t, a, err), Projection(t, I64, err), List(I64) -> Table(t, a, err)
	filter_in = |table, column, values|
		table.add_filter(Filter.in_i64(column, values))

	filter_in_str : Table(t, a, err), Projection(t, Str, err), List(Str) -> Table(t, a, err)
	filter_in_str = |table, column, values|
		table.add_filter(Filter.in_str(column, values))

	add_filter : Table(t, a, err), Filter -> Table(t, a, err)
	add_filter = |table, filter|
		Table.{
			name: table.name,
			columns: table.columns,
			decoder: table.decoder,
			filters: table.filters.append(filter),
		}

	# The `WHERE` clause, filters joined with `AND`; empty when unfiltered.
	where_clause : Table(t, a, err) -> Str
	where_clause = |table|
		if List.is_empty(table.filters) {
			""
		} else {
			" WHERE ${Str.join_with(table.filters.map(|filter| filter.sql), " AND ")}"
		}

	# The statement this table projection runs.
	to_sql : Table(t, a, err) -> Str
	to_sql = |table|
		"SELECT ${Str.join_with(table.columns.map(quote_column), ", ")} FROM ${table.name}${table.where_clause()} ORDER BY id"

	# The values for its `?` markers, in order.
	to_params : Table(t, a, err) -> List(Sqlite.Value)
	to_params = |table| {
		var $params = []
		for filter in table.filters {
			$params = $params.concat(filter.params)
		}
		$params
	}

	# Run it: the columns become the SELECT list, the decoders read the rows,
	# and the filters are bound as parameters.
	query! : Table(t, a, err), Sqlite.Db => Try(List(a), _)
	query! = |table, db| {
		db.query_all!(Sqlite.Query.new(table.to_sql(), table.to_params()), table.decoder)
	}
}

# The filters themselves, next to the `filter_in` shorthands that use them.
Filter := { sql : Str, params : List(Sqlite.Value) }.{
	in_i64 : Projection(t, I64, err), List(I64) -> Filter
	in_i64 = |column, values| Filter.in_sql(column, values.map(|value| Integer(value)))

	in_str : Projection(t, Str, err), List(Str) -> Filter
	in_str = |column, values| Filter.in_sql(column, values.map(|value| String(value)))

	in_sql : Projection(t, e, err), List(Sqlite.Value) -> Filter
	in_sql = |column, values| {
		# `IN ()` is a syntax error, so an empty list becomes `0`: match
		# nothing, the same meaning `IN` over no values would have.
		name = column.to_columns().get(0) ?? crash "a filter needs one column"
		sql = if List.is_empty(values) {
			"0"
		} else {
			marks = Str.join_with(values.map(|_| "?"), ", ")
			"${quote_column(name)} IN (${marks})"
		}
		Filter.{ sql, params: values }
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

# The SQL table name lives here, once per tag, next to the projection it names.
invoice_table : Table(Invoices, Invoice, _)
invoice_table =
	Table.from_projection("invoices", { id, number, customer, status, paid_on }.Projection)

invoice_row_table : Table(InvoiceRows, InvoiceRow, _)
invoice_row_table =
	Table.from_projection(
		"invoice_rows",
		{ row_id, invoice_id, description, quantity, unit_cents }.Projection,
	)

# The SQL names exactly the columns the projection carries.
quote_column : Str -> Str
quote_column = |name| "\"${name}\""

main! = |_| {
	db = Sqlite.open_in_memory!()?
	setup!(db)?

	Stdout.line!("Invoices, id and number, selected from the table projection:")?
	for invoice in invoice_table.select({ id, number }.Projection).query!(db)? {
		Stdout.line!("  #${invoice.id.to_str()}  ${invoice.number}")?
	}

	Stdout.line!("")?
	Stdout.line!("Invoices, number and status:")?
	for invoice in invoice_table.select({ number, status }.Projection).query!(db)? {
		Stdout.line!("  ${invoice.number}  ${status_to_str(invoice.status)}")?
	}

	# Filters are `WHERE` terms, so they may name a column the `select`
	# dropped: `id` is not among the output columns below, but it is still a
	# column of `invoices`. Chain them in either order.
	Stdout.line!("")?
	Stdout.line!("Invoices 1 and 3, filtered then selected:")?
	for invoice in invoice_table.filter_in(id, [1, 3]).select({ number, status }.Projection).query!(db)? {
		Stdout.line!("  ${invoice.number}  ${status_to_str(invoice.status)}")?
	}

	Stdout.line!("")?
	Stdout.line!("Same, selected then filtered:")?
	for invoice in invoice_table.select({ number, status }.Projection).filter_in(id, [1, 3]).query!(db)? {
		Stdout.line!("  ${invoice.number}  ${status_to_str(invoice.status)}")?
	}

	Stdout.line!("")?
	Stdout.line!("Two filters are ANDed, with parameters bound in order:")?
	filtered = invoice_table
		.filter_in(id, [1, 2, 3])
		.filter_in_str(customer, ["Acme Ltd", "Initech"])
		.select({ customer, status }.Projection)
	Stdout.line!("  ${Table.to_sql(filtered)}")?
	for invoice in filtered.query!(db)? {
		Stdout.line!("  ${invoice.customer}  ${status_to_str(invoice.status)}")?
	}

	Stdout.line!("")?
	Stdout.line!("An empty id list matches nothing:")?
	for invoice in invoice_table.filter_in(id, []).select({ number, status }.Projection).query!(db)? {
		Stdout.line!("  ${invoice.number}")?
	}
	Stdout.line!("  (no rows)")?

	Stdout.line!("")?
	Stdout.line!("Invoices, every column:")?
	for invoice in invoice_table.query!(db)? {
		paid = match invoice.paid_on {
			Ok(date) => "paid ${date}"
			Err(Null) => "open"
		}
		Stdout.line!("  #${invoice.id.to_str()}  ${invoice.number}  ${invoice.customer}  ${status_to_str(invoice.status)}  (${paid})")?
	}

	Stdout.line!("")?
	Stdout.line!("Invoice rows, description and quantity, selected from the row projection:")?
	for row in invoice_row_table.select({ description, quantity }.Projection).query!(db)? {
		Stdout.line!("  ${row.description}  ${row.quantity.to_str()}")?
	}

	Stdout.line!("")?
	Stdout.line!("Invoice rows, every column:")?
	for row in invoice_row_table.query!(db)? {
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
