## An in-memory SQLite database with two related tables, `invoices` and
## `invoice_rows`. A `Table` is a record of typed columns bound to a table, so
## `query!` selects exactly those columns and each query is a record shape.
## `Table` is a projection bound to its table and cannot change; `select` and
## `filter_in` return a `Queryable` that holds the table's metadata plus the
## selected projection, so a query accumulates bound `WHERE ... IN (...)` terms
## without the table's definition changing. Filterability is a phantom type
## parameter on the column's own type, so only a column annotated
## `IsFilterable` may appear in a `WHERE`.
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

# Filter flags: phantom types marking whether a column may appear in a `WHERE`.
#
# Columns are built `NotFilterable`, and only `Projection.filterable` re-tags
# one. `filter_in` demands `IsFilterable`, so filtering a column is an explicit,
# reviewable opt-in written into that column's annotation — `unit_cents` has
# none, so it cannot be filtered on. Roc has no module privacy, so an
# `IsFilterable` can still be minted anywhere in the file; the flag makes the
# opt-in visible, not impossible.
IsFilterable := {}

NotFilterable := {}

# A decoder paired with the columns it reads. `Sqlite.Decoder` is opaque, so
# its own column list cannot drive the SQL; this keeps a visible copy alongside
# it, built by the same call. The `flag` parameter is phantom: it never reaches
# a value, and exists only to carry filterability in the type.
Projection(table, flag, a, err) := { columns : List(Str), decoder : Decoder(a, err) }.{
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
	map2 :
		Projection(t, f1, a, err),
		Projection(t, f2, b, err),
		(a, b -> c) -> Projection(
			t,
			NotFilterable,
			c,
			err,
		)
	map2 = |first, second, combine|
		Projection.{
			columns: first.columns.concat(second.columns),
			decoder: Decoder.map2(first.decoder, second.decoder, combine),
		}

	# One column, from any leaf decoder.
	field : Str, (Sqlite.Column -> Decoder(a, err)) -> Projection(t, NotFilterable, a, err)
	field = |name, make| {
		column = Sqlite.Column.from_quote(name) ?? crash "a column name is a plain Str"
		Projection.{ columns: [name], decoder: make(column) }
	}

	str : Str -> Projection(t, NotFilterable, Str, _)
	str = |name| field(name, Decoder.str)

	i64 : Str -> Projection(t, NotFilterable, I64, _)
	i64 = |name| field(name, Decoder.i64)

	# Accept SQL `NULL`, decoding to `Err(Null)` when the column is NULL.
	nullable : Projection(t, flag, a, err) -> Projection(t, flag, Try(a, [Null]), err)
	nullable = |projection|
		Projection.{
			columns: projection.columns,
			decoder: projection.decoder.nullable(),
		}

	# Transform the decoded value with a function that can fail.
	map_try : Projection(t, flag, a, err), (a -> Try(b, err)) -> Projection(t, flag, b, err)
	map_try = |projection, transform|
		Projection.{
			columns: projection.columns,
			decoder: projection.decoder.map_try(transform),
		}

	# The columns this projection reads, for building SQL or for tests.
	to_columns : Projection(t, flag, a, err) -> List(Str)
	to_columns = |projection| projection.columns

	# Opt a column into `WHERE`: the only way to obtain an `IsFilterable`.
	filterable : Projection(t, flag, a, err) -> Projection(t, IsFilterable, a, err)
	filterable = |projection|
		Projection.{ columns: projection.columns, decoder: projection.decoder }

	# Drop the flag, for storing a projection where filterability is irrelevant.
	as_plain : Projection(t, flag, a, err) -> Projection(t, NotFilterable, a, err)
	as_plain = |projection|
		Projection.{ columns: projection.columns, decoder: projection.decoder }

	# Re-tag as `IsFilterable` only if the column can be one: a value-level
	# check for the case where the name came from data rather than a constant.
	try_filterable : Projection(t, flag, a, err) -> Try(Projection(t, IsFilterable, a, err), [ManyColumns])
	try_filterable = |projection|
		if projection.columns.len() == 1 {
			Ok(Projection.filterable(projection))
		} else {
			Err(ManyColumns)
		}
}

# One `WHERE` term: SQL with `?` markers, and the values for them.
no_filters : List(Filter)
no_filters = []

# A table's identity: its name and its full column list, with no decoder and
# so no row type. This is the part a query keeps as it narrows — the decoder
# travels in the projection instead, because it changes with `select`.
TableMeta(table) := { name : Str, columns : List(Str) }.{
	from_projection : Str, Projection(table, flag, a, err) -> TableMeta(table)
	from_projection = |name, projection| TableMeta.{ name, columns: projection.columns }

	to_columns : TableMeta(table) -> List(Str)
	to_columns = |meta| meta.columns
}

# A projection bound to its table: the metadata plus the decoder for the full
# row. It cannot change; `select` and `filter_in` return a `Queryable`.
Table(table, a, err) := {
	meta : TableMeta(table),
	projection : Projection(table, NotFilterable, a, err),
}.{
	from_projection : Str, Projection(table, flag, a, err) -> Table(table, a, err)
	from_projection = |name, projection|
		Table.{
			meta: TableMeta.from_projection(name, projection),
			projection: Projection.as_plain(projection),
		}

	to_columns : Table(table, a, err) -> List(Str)
	to_columns = |table| table.meta.to_columns()

	to_decoder : Table(table, a, err) -> Decoder(a, err)
	to_decoder = |table| table.projection.decoder

	# Start a queryable: the whole row, no filters.
	to_query : Table(table, a, err) -> Queryable(table, a, err)
	to_query = |table|
		Queryable.{
			table: table.meta,
			projection: table.projection,
			filters: no_filters,
		}

	select : Table(table, a, err), Projection(table, flag, b, err) -> Queryable(table, b, err)
	select = |table, picked| table.to_query().select(picked)

	filter_in : Table(table, a, err), Projection(table, IsFilterable, I64, err), List(I64) -> Queryable(table, a, err)
	filter_in = |table, key, values| table.to_query().filter_in(key, values)

	filter_in_str : Table(table, a, err), Projection(table, IsFilterable, Str, err), List(Str) -> Queryable(table, a, err)
	filter_in_str = |table, key, values| table.to_query().filter_in_str(key, values)

	query! : Table(table, a, err), Sqlite.Db => Try(List(a), _)
	query! = |table, db| table.to_query().query!(db)
}

# A table projection that can be queried: the table's identity, the columns
# selected so far, and the filters to apply.
#
# `table` keeps the full column list, so a filter or a later `select` may still
# name a column an earlier `select` dropped; `projection` carries both the
# selected column names and their decoders, so the two cannot drift.
Queryable(table, a, err) := {
	table : TableMeta(table),
	projection : Projection(table, NotFilterable, a, err),
	filters : List(Filter),
}.{
	# Narrow the output to the columns picked.
	#
	# The type parameter already guarantees the picked columns come from this
	# table: `Projection(t, …)` unifies only with columns built for the same
	# tag, so a cross-table pick is a compile error before this is reached.
	# The loop is the remaining runtime guard: a column constant whose name is
	# not in the table (a typo in `Projection.str`) would otherwise produce SQL
	# selecting a name the table may not have.
	select : Queryable(table, a, err), Projection(table, flag, b, err) -> Queryable(table, b, err)
	select = |query, picked| {
		for name in picked.columns {
			if !List.contains(query.table.columns, name) {
				crash "not a column of ${query.table.name}: ${Str.inspect(name)}"
			}
		}
		Queryable.{
			table: query.table,
			projection: Projection.as_plain(picked),
			filters: query.filters,
		}
	}

	# Keep the rows whose column is one of `values`, as SQL `IN`.
	filter_in : Queryable(table, a, err), Projection(table, IsFilterable, I64, err), List(I64) -> Queryable(table, a, err)
	filter_in = |query, key, values| query.add_filter(Filter.in_i64(key, values))

	filter_in_str : Queryable(table, a, err), Projection(table, IsFilterable, Str, err), List(Str) -> Queryable(table, a, err)
	filter_in_str = |query, key, values| query.add_filter(Filter.in_str(key, values))

	add_filter : Queryable(table, a, err), Filter -> Queryable(table, a, err)
	add_filter = |query, filter|
		Queryable.{
			table: query.table,
			projection: query.projection,
			filters: query.filters.append(filter),
		}

	# The `WHERE` clause, filters joined with `AND`; empty when unfiltered.
	where_clause : Queryable(table, a, err) -> Str
	where_clause = |query|
		if List.is_empty(query.filters) {
			""
		} else {
			" WHERE ${Str.join_with(query.filters.map(|filter| filter.sql), " AND ")}"
		}

	# The statement this query runs.
	to_sql : Queryable(table, a, err) -> Str
	to_sql = |query|
		"SELECT ${Str.join_with(query.projection.columns.map(quote_column), ", ")} FROM ${query.table.name}${query.where_clause()} ORDER BY id"

	# The values for its `?` markers, in order.
	to_params : Queryable(table, a, err) -> List(Sqlite.Value)
	to_params = |query| {
		var $params = []
		for filter in query.filters {
			$params = $params.concat(filter.params)
		}
		$params
	}

	# Run it: the selected columns become the SELECT list, the decoders read
	# the rows, and the filters are bound as parameters.
	query! : Queryable(table, a, err), Sqlite.Db => Try(List(a), _)
	query! = |query, db| {
		db.query_all!(Sqlite.Query.new(query.to_sql(), query.to_params()), query.projection.decoder)
	}
}

# The filters themselves, next to the `filter_in` shorthands that use them.
Filter := { sql : Str, params : List(Sqlite.Value) }.{
	in_i64 : Projection(t, IsFilterable, I64, err), List(I64) -> Filter
	in_i64 = |key, values| Filter.in_sql(key, values.map(|value| Integer(value)))

	in_str : Projection(t, IsFilterable, Str, err), List(Str) -> Filter
	in_str = |key, values| Filter.in_sql(key, values.map(|value| String(value)))

	in_sql : Projection(t, IsFilterable, e, err), List(Sqlite.Value) -> Filter
	in_sql = |key, values| {
		# `IN ()` is a syntax error, so an empty list becomes `0`: match
		# nothing, the same meaning `IN` over no values would have.
		name = key.to_columns().get(0) ?? crash "a filter needs one column"
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
# The second type argument is the filter flag. A column annotated
# `IsFilterable` can appear in a `WHERE`; one annotated `NotFilterable` cannot.
# That annotation, plus the `Projection.filterable` call beside it, is the whole
# opt-in — there is no separate list to keep in step.
#
# They sit above `main!` because a punned record literal inside a function body
# does not see top-level definitions declared later in the file (a limitation of
# this nightly); ordinary name references are order-independent.
id : Projection(Invoices, IsFilterable, I64, _)
id = Projection.filterable(Projection.i64("id"))

number : Projection(Invoices, NotFilterable, Str, _)
number = Projection.str("number")

customer : Projection(Invoices, IsFilterable, Str, _)
customer = Projection.filterable(Projection.str("customer"))

status : Projection(Invoices, NotFilterable, Status, _)
status = Projection.str("status").map_try(status_from_str)

paid_on : Projection(Invoices, NotFilterable, Try(Str, [Null]), _)
paid_on = Projection.nullable(Projection.str("paid_on"))

row_id : Projection(InvoiceRows, IsFilterable, I64, _)
row_id = Projection.filterable(Projection.i64("id"))

invoice_id : Projection(InvoiceRows, IsFilterable, I64, _)
invoice_id = Projection.filterable(Projection.i64("invoice_id"))

description : Projection(InvoiceRows, NotFilterable, Str, _)
description = Projection.str("description")

quantity : Projection(InvoiceRows, NotFilterable, I64, _)
quantity = Projection.i64("quantity")

unit_cents : Projection(InvoiceRows, NotFilterable, I64, _)
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
	Stdout.line!("  ${Queryable.to_sql(filtered)}")?
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
	Stdout.line!("Invoice rows of invoice 1, filtered on a filterable column:")?
	for row in invoice_row_table
		.filter_in(invoice_id, [1])
		.select({ description, quantity }.Projection)
		.query!(db)? {
		Stdout.line!("  ${row.description}  ${row.quantity.to_str()}")?
	}

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
