//! Stateless middleware composition specialized at compile time.
//!
//! A middleware type implements `call(ctx, next_fn)`. Unlike the dynamic
//! `Middleware` API this path stores no slice/index and performs no indirect
//! middleware dispatch. Stateful and dynamically selected middleware should
//! continue to use `App.use`/`App.useAll`.

pub fn Chain(comptime ContextType: type, comptime middleware_types: []const type, comptime terminal: anytype) type {
    return struct {
        pub fn run(c: *ContextType) anyerror!void {
            return Layer(0).call(c);
        }

        fn Layer(comptime index: usize) type {
            return struct {
                fn call(c: *ContextType) anyerror!void {
                    if (comptime index == middleware_types.len) return terminal(c);
                    const M = middleware_types[index];
                    return M.call(c, Layer(index + 1).call);
                }
            };
        }
    };
}
