// Public entry point for the model layer. Users do:
//
//     const model = @import("akamata").model;
//     const td = model.tableDef(User);
//
// Sub-modules:
//   - schema.zig   — comptime introspection (struct + __schema → TableDef)
//   - ddl.zig      — TableDef → CREATE TABLE / CREATE INDEX (P2)
//   - validate.zig — validation rules (P3)
//   - query.zig    — find/all/where/save/delete (P4)
//   - migrate.zig  — diff vs real DB + apply (P5)
//   - relations.zig — belongs_to / has_many (P6)

pub const schema = @import("schema.zig");
pub const ddl = @import("ddl.zig");
pub const validate_mod = @import("validate.zig");
pub const query = @import("query.zig");
pub const migrate = @import("migrate.zig");
pub const relations = @import("relations.zig");
pub const preload = @import("preload.zig");

pub const Repo = query.Repo;
pub const repo = query.repo;

pub const TableDef = schema.TableDef;
pub const Column = schema.Column;
pub const Index = schema.Index;
pub const SqlType = schema.SqlType;
pub const tableDef = schema.tableDef;

pub const rule = validate_mod.rule;
pub const Rule = validate_mod.Rule;
pub const Format = validate_mod.Format;
pub const ValidationError = validate_mod.ValidationError;
pub const validate = validate_mod.validate;
